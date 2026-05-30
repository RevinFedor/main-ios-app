# Привычки — основной user-flow

Habits tab — вторая вкладка приложения. Список карточек-привычек сгруппированных в `HabitGroup`. Каждая карточка — название слева + матрица точек прогресса справа.

## Gestures-first, без Edit-mode

В приложении **нет** кнопки «Edit / Карандаш». Все действия — жестами. Три разных жеста на одной строке, различаются **временем** (tap vs hold) и **движением** (release vs drag):

| Жест | Привычка | Группа |
|------|----------|--------|
| **Quick tap** (<0.3s) | по чекмарку → toggle `done/missed` того дня; по левой части → ничего | по левой части (chevron+имя) → expand/collapse; по правой → ничего |
| **Press + release** (held ≥0.3s, отпустил без движения) | edit sheet | edit sheet |
| **Press + drag** (held ≥0.3s, повёл) | reorder внутри/между группами | reorder |

Ключевой инвариант: **tap ≠ press**. Быстрый тап и «зажал-почувствовал-отпустил» — два РАЗНЫХ действия. Press (edit) и drag (reorder) работают по **всей ширине строки**; quick-tap роутится по X-координате.

### Реализация жестов (`ContentView.swift`) — backbone от Gemini 3.1 Pro research

**Все жесты владеются родителем** (`reorderableList`); строки (`HabitRowView`/`GroupRowView`) — чисто визуальные, без своих `Button`/`.onTapGesture`. Это убрало double-tap-баг и «второй фон» у заголовка разом.

- **Quick tap** — `.onTapGesture(coordinateSpace:.local) { loc in handleTap(...) }`. Роутер смотрит `loc.x`: левая зона (< `hPadding+leftZoneWidth` = 12+140=152) vs зона чекмарков и какой день (`(rowWidth-164)/days.count`). Ширина строки — из `GeometryReader` вокруг `ScrollView`. Константы `hPadding`/`leftZoneWidth` ОБЯЗАНЫ совпадать с `.padding(.horizontal,12)` и `.frame(width:140)` в row-вьюхах.
- **Press / drag** — `.gesture(LongPressGesture(0.3, maxDistance:10).sequenced(before: DragGesture(minimumDistance:3, coordinateSpace:.global)))`. `.first(true)` (0.3s) → подсветить строку через `@GestureState pressedRow` (`.updating`, НЕ `@State` — см. регрессии ниже). `.second` → drag-фаза; `hypot(translation)>10` **live в `.onChanged`** (не в onEnded) → `didDragMeaningfully`. `.onEnded`: двигал → reorder, не двигал → edit. ⚠️ `coordinateSpace:.global` ОБЯЗАТЕЛЕН (не `.local`) т.к. строка двигается `.offset` из этого же translation — `.local` создаёт петлю обратной связи (см. `### Истинная причина` внизу).
- **Почему tap и press не съедают друг друга**: оба standard-priority, temporal race. Tap <0.3s распознаётся первым и форсит long-press в fail; hold ≥0.3s — long-press succeeds и форсит tap в fail. НЕ использовать `ExclusiveGesture(tap.exclusively(before:longPress))` — `TapGesture` без таймаута блокирует long-press-таймер (ловушка из research).
- **Почему скролл работает**: быстрый свайп проходит >10pt раньше 0.3s → `maxDistance:10` роняет long-press, движение роняет tap → оба row-жеста отпускают touch, `ScrollView` pan забирает. Поэтому **не** `.simultaneousGesture` (перетягивает арбитра, ломает скролл) и **не** `.highPriorityGesture`.
- **Почему НЕ `Button` внутри строки** (double-tap bug): `Button` под родительским long-press'ом — система задерживает touch ребёнку и прерывает touch-sequence на полпути → «первый тап подсветил, второй сработал». Чекмарк-toggle делается location-роутером на родителе. Если когда-нибудь нужен вложенный tap-приёмник под row-gesture — только `.highPriorityGesture(TapGesture())`, не `Button`.
- **Highlight только при press (0.3s)**, не на каждый touch-down — quick-tap (toggle) мгновенный и мигать не должен; подсветка = сигнал «сейчас edit/drag».
- **Top + bottom borders на КАЖДОЙ строке** (не общий divider) — иначе при offset соседей во время drag виден «шов».

### Плавный drag без джерка (Gemini 3.1 Pro research)

Перетаскиваемый элемент дёргался. Четыре причины по приоритету (все исправлены):

1. **CRITICAL — re-sort `allItems` каждый кадр.** `draggingOffset` это `@State` на `ContentView` → каждый кадр drag'а (120 Гц на ProMotion) ре-evaluate'ит body → `ForEach(store.allItems)` + `offsetForRow` пересортировывают и переплющивают список O(n log n) на main thread → дропы кадров. **Фикс:** `@State dragSnapshot: [HabitItem]?` — замораживается = `store.allItems` в момент старта drag'а (фаза `.second`, `draggingIndex == nil`); во время drag рендер идёт из `displayItems` (`dragSnapshot ?? store.allItems`); очищается в `onEnded`. Индексы snapshot'а == индексы `store.allItems` (стор не мутируется во время drag), поэтому `reorderItem(from:to:)` получает корректные индексы.
2. ~~**CRITICAL — ScrollView дерётся с drag → `.scrollDisabled(draggingIndex != nil)`.**~~ **ОТМЕНЕНО — оказалось ложной теорией.** Подробно в `### Истинная причина` ниже. Кратко: (а) on-device логи доказали, что ScrollView жест НЕ отменяет (72 кадра отстреляли, `onEnded` вызвался); (б) переключение `.scrollDisabled` mid-gesture, наоборот, РЕinstall'ит recognizer'ы ScrollView и **отменяет** весь `.exclusively(drag, before: tap)` стек → намертво убивает tap/expand/long-press и оставляет залипшую подсветку `@GestureState`. `.scrollDisabled` **удалён полностью**. Реальный джерк лечится не им — см. ниже.
3. **HIGH — `.animation(value:)` течёт в dragged row.** У перетаскиваемого должно быть 0 анимации (трекинг пальца 1:1); анимируют make-room сдвиг только НЕ-dragged строки. Реализовано тернаром `isDragging ? nil : .interactiveSpring`. Во время `.onChanged` НЕ оборачивать мутации в `withAnimation` — иначе ambient-анимация просочится в dragged.
4. ~~**MEDIUM — LazyVStack recycling → VStack.**~~ **РЕВЕРСНУТО.** VStack пересобирал ВСЕ строки каждый кадр при 120Hz `draggingOffset` → тяжесть росла с числом строк (worst на раскрытой группе 8 привычек). Вернули **`LazyVStack`** — только видимые строки. Recycling-flicker не возникает: скролла во время драга по факту нет (палец держит drag, не pan), а offset считается index-математикой, не live-фреймами. См. `### Истинная причина`.

Reorder-движок (`HabitStore.reorderItem` + cross-group edge-кейсы) при этом НЕ трогался — чинился только слой рендера.

### Регрессии после первого фикса (5-агентный workflow) — что реально вернуло «лёгкий» драг

Первый заход (VStack + `.scrollDisabled` + per-row `.onTapGesture` + `DragGesture(minDist:0)` + `@State pressedIndex`) сделал драг **тугим/тяжёлым** и оставлял **залипший фон** после тапа. Workflow (3 диагностических агента + синтез) нашёл 3 корня:

1. **Залипший фон при тапе → `@GestureState`, не `@State`.** `pressedIndex` (@State) ставился в `.first(true)` long-press'а, а чистился только в `.onEnded`. Тап, провисевший ~0.3s, успевал зажечь подсветку, затем выигрывал арбитраж и **отменял** sequenced-жест → `.onEnded` НЕ вызывается (у SwiftUI-жестов нет `onCancelled`) → defer не отрабатывает → фон залип. **Фикс:** подсветка через `@GestureState private var pressedRow: Int?` + `.updating`. GestureState авто-сбрасывается в nil при end **и** cancel — точная Apple press-flash семантика, структурно не может залипнуть. Тип ОБЯЗАН быть `Int?` (какая строка нажата), не коллекция: один shared `@GestureState` на все per-row жесты сбрасывается целиком когда ЛЮБОЙ из них кончается — но т.к. активен всегда один палец, `Int?` корректен.
2. **Тяжесть драга = DateFormatter storm.** `DateHelper.dateKey` создавал **новый `DateFormatter` на каждый вызов** (одна из самых дорогих операций Foundation — поднимает ICU/CFDateFormatter). `weekDates()` зовёт его 8×; каждая строка звала `weekDates()` в своём body; `draggingOffset` (@State) → body переоценивается 120×/с → `8 × N_строк × 120` аллокаций/с на main thread. **Фикс:** (а) один кэшированный `static let keyFormatter` в DateHelper — байт-в-байт те же ключи (locale не трогали, чтобы существующая history совпадала); (б) `weekDates` считается ОДИН раз в `reorderableList` и прокидывается в строки параметром `days: [WeekDay]` (а не вычисляется в каждом row body).
3. **Тугой старт драга = `.scrollDisabled` toggled mid-gesture + `minDist:0` + competing `.onTapGesture`.**
   - Переключение `.scrollDisabled(draggingIndex != nil)` В МОМЕНТ старта drag заставляло UIScrollView реконфигурировать pan-recognizer → видимый рывок ровно на старте. **Убрано полностью** — 0.3s long-press сам выигрывает арбитраж у скролла для удержания, а быстрый свайп (без 0.3s) скроллит.
   - `DragGesture(minimumDistance: 0)` → суб-пиксельный тремор палец→offset без мёртвой зоны. **Вернул `minimumDistance: 3`** (как в оригинале) — мёртвая зона сглаживает старт.
   - Конкурирующий `.onTapGesture` заставлял систему держать touch для дизамбигуации → лаг. **Заменён на** `dragGesture(at:).exclusively(before: SpatialTapGesture(...))`: press имеет приоритет, tap срабатывает только если press НЕ выиграл; `SpatialTapGesture` даёт `value.location` для X-роутинга (порядок `press.exclusively(before: tap)` КРИТИЧЕН — наоборот tap проглотит long-press и сломает reorder).

### Истинная причина «дёрганья и from=N-to=N» — coordinate-space feedback loop

**Это финальный, доказанный логами с устройства диагноз. Всё, что выше про `scrollDisabled` и «ScrollView отменяет DragGesture» — ложные теории, перечёркнуты.**

Чтобы наконец увидеть правду, добавили **диагностическое логирование** прямо в жест (читается из App-Group лога без Xcode):
- `.onChange(of: pressedRow)` → `press ENGAGE` (nil→idx) и `press RELEASE` (idx→nil). RELEASE без предшествующего `onEnded` = жест был **отменён** (у SwiftUI-жестов нет `onCancelled`).
- счётчик кадров `dragFrames`, throttled `drag move dy=… frame=…` каждые ~20pt, и `onEnded …frames=… finalDy=…`.

Логи раскрыли всё разом. Медленный драг группы вверх:
```
drag move dy=-23 frame=5
drag move dy=-65 frame=31   ← растёт (палец вверх)
drag move dy=-35 frame=40   ← схлопывается обратно ↓
drag move dy=-7  frame=47   ← почти ноль, палец ВСЁ ЕЩЁ зажат
onEnded REORDER from=3 to=3 frames=72 finalDy=5   ← 72 кадра, finalDy≈0 → to==from
press RELEASE row=3                                ← ПОСЛЕ onEnded
```
Быстрый решительный драг привычки вниз: `dy=25→53→76→97→122→143` (монотонно) → `from=2 to=5` ✓.

Что это доказывает:
1. **Жест НЕ отменяется.** 72 кадра, `onEnded` отработал, `RELEASE` пришёл ПОСЛЕ `onEnded`. Теория «ScrollView cancels DragGesture mid-move» — **опровергнута**. Удаление `scrollDisabled` было правильным (tap/expand/long-press снова живы), но это была не причина джерка.
2. **Реальный баг — петля обратной связи по системе координат.** Перетаскиваемая строка двигается `.offset(y: draggingOffset)`, а `draggingOffset` = `translation.height` DragGesture'а, измеренный в **`.local`**. Когда строка сдвигается, её локальный origin едет вместе с ней → следующий `translation` меряется от съехавшего фрейма → `dy` осциллирует: лезет к −65, потом схлопывается к +5, пока палец ещё зажат. Схлопывание → `finalDy≈0` → `to==from`. Быстрый драг «срабатывал» только потому, что обгонял петлю до того, как она свернётся.

**Фикс — одно слово: `coordinateSpace: .local` → `.global`** на DragGesture.
`.global` — экранное пространство; `.offset` его не двигает, поэтому `translation` трекает палец 1:1, петли нет. Семантика дельты не меняется (`offsetForRow`/`calculateTargetIndex` считают тот же `CGFloat(index)*rowHeight`), меняется только система отсчёта.

**Инвариант на будущее:** в SwiftUI, если строку двигаешь `.offset(...)` величиной из *того же* DragGesture, его `coordinateSpace` ОБЯЗАН быть `.global` (или `.named` у неподвижного контейнера), НИКОГДА не `.local` — иначе offset кормит сам себя. Это классическая ловушка, документирована в комментарии у `dragGesture(at:)`.

Итоговая рабочая комбинация (текущее состояние кода):
1. **`LazyVStack`** (не VStack). VStack пересобирал ВСЕ строки каждый кадр при 120Hz `draggingOffset` → тяжесть, растущая с числом строк (воспроизводилось на раскрытой группе с 8 привычками). Lazy — только видимые.
2. **`DragGesture(minimumDistance: 3, coordinateSpace: .global)`** — `.global` убивает петлю (см. выше), `minDist:3` даёт мёртвую зону на старте.
3. **НЕТ `.scrollDisabled`.** Скролл vs драг разруливается темпорально long-press'ом (0.3s держишь → драг; быстрый свайп роняет long-press по `maxDistance:10` → скролл). Mid-gesture toggle `.scrollDisabled` ЗАПРЕЩЁН — отменяет жест.
4. **`.onChange(of: pressedRow)`** оставлен как детектор отмены жеста для будущей диагностики.

### Диагностика / логи

Habits переиспользует `VRLog` (тот же App-Group файл `voice-record-debug.log`, что и Voice — единый diagnostic buffer). События пишутся через `VRLog.d("HABIT", ...)`. **Жест трассируется по фазам** (это и раскрыло coordinate-space-петлю — см. выше): `press ENGAGE/RELEASE` (через `.onChange(of: pressedRow)`), `phase=PRESS`, `drag START`, throttled `drag move dy=… frame=…` (каждые ~20pt), `onEnded REORDER from=… to=… frames=… finalDy=…` / `onEnded EDIT`, плюс tap-роутер (`tap toggle/expand/no-op`). Диагностический приём, который сработал: **RELEASE без предшествующего `onEnded` = жест отменён** (у SwiftUI-жестов нет `onCancelled`-колбэка, отмену видно только так). НЕ писать в лог на КАЖДЫЙ кадр (`append` переписывает весь файл) — отсюда throttle по 20pt. UI:
- **Navbar Habits, справа** — `doc.on.doc` (копировать недавний лог) + `trash` (очистить). Быстрый доступ без ухода с экрана.
- **Settings → Диагностика** — «Показать лог» (лупа) открывает `DiagnosticsLogView` (reusable, `Views/Components/DiagnosticsLogView.swift`): полный просмотрщик с меню `…` → Copy all / Share log (.txt через tmp-файл) / Clear / Refresh / Done. Плюс те же quick copy/clear иконки. Это копия `LogViewerSheet` из `VoiceSettingsSheet` — Voice-версию не трогали (она `private`), сделали общий компонент.

Философское обоснование «зачем убрали Edit-режим» — `methodology/переносимый-дизайн.md::Gestures-first`.

## Режимы отображения истории

Две схемы для сетки дней (выбирается в Settings):
- **Week-based (Mon/Sun)**: сетка привязана к календарной неделе. Понедельник всегда крайний слева. Юзер видит «эту неделю».
- **Relative (Относительно сегодня)**: сетка всегда показывает текущий день на **предпоследней** позиции (penultimate). То есть справа от «сегодня» — 1 день будущего, слева — 5-6 дней прошлого. Дизайн-решение: contextual «что было до и что будет завтра», без жёсткой привязки к календарю.

Режим хранится в App Group и применяется одинаково в app и в виджете.

## Today highlight

Текущий день в сетке выделен **фоновым кругом** `Color.blue.opacity(0.25)` под буквой дня недели. Не жирным шрифтом — на плотной сетке (особенно small-виджет) bold-текст размывается среди соседних дней. Fill-shape читается мгновенно. Принцип в общем виде — `methodology/переносимый-дизайн.md::Сегодняшний день — фоновый якорь`.

## Локализация дней недели

В матрице и в виджете дни недели — **2-буквенные русские сокращения** (ПН, ВТ, СР, ЧТ, ПТ, СБ, ВС). Не цифры, не однобуквенные. Однобуквенные сокращения В/С/П/Ч неоднозначны (В = вторник или воскресенье?). Двухбуквенные — компромисс: помещается в сетку 2×2 виджета и не путается.

## Связанное

- `fact-habit-widget.md` — Home Screen виджеты для этого же datasource.
- `fix-ios-stability.md` — App Groups, дублирование моделей, widget reload.
