# Knowledge: iOS & SwiftUI Stability

## 🛠 ОПЫТ: Исправления и ограничения

### 1. Widget Deployment Target
**Проблема**: Виджет не появляется в галерее или выдает ошибку `Error Domain=com.apple.dt.deviceprocesscontrolservice Code=8`.
**Причина**: Xcode при создании Widget Extension автоматически ставит `IPHONEOS_DEPLOYMENT_TARGET` равным версии текущего SDK (напр. 26.2). Если устройство имеет версию 26.1, виджет не загрузится.
**Решение**: Всегда вручную снижать Deployment Target виджета до минимально поддерживаемой (напр. 18.0), даже если используются API iOS 26.

### 2. Glass Rendering Constraints (iOS 26)
**Факт**: Система Liquid Glass динамически изменяет фон и контрастность виджета.
- **Ограничение**: Нельзя полагаться на фиксированные цвета фона внутри виджета.
- **Решение**: Использовать `.containerBackground(for: .widget)` и `.widgetAccentable()`. Без этого элементы могут "исчезнуть" при смене темы оформления пользователем.

### 3. Duplicate Models Motivation
**Почему не Framework?**: В маленьких проектах создание отдельного Framework/Library для общих моделей часто приводит к проблемам с Code Signing и Bundle ID в Xcode.
**Решение**: Мы выбрали дублирование файлов моделей в таргет виджета. 
- **Критическое правило**: При изменении структуры `Habit` или `StorageData` в основном приложении, необходимо СИНХРОННО обновить эти структуры в `HabitWidget_.swift`. Несовпадение форматов JSON приведет к поломке виджета (silent failure).

### 4. App Groups Permissions
**Факт**: Наличие кода для App Groups недостаточно. 
- **Обязательно**: Файлы `.entitlements` должны быть прописаны в `CODE_SIGN_ENTITLEMENTS` внутри `project.pbxproj` для ВСЕХ конфигураций (Debug/Release). Без этого `UserDefaults(suiteName:)` вернет `nil` без ошибок.

### 5. Widget Refresh Lag
**Проблема**: После изменения данных в приложении виджет продолжает показывать старые данные в течение нескольких секунд или до следующего системного обновления.
**Причина**: `UserDefaults` кеширует данные в памяти и не всегда успевает сбросить их на диск до того, как расширение виджета попытается их прочитать.
**Решение**: Вызов `sharedDefaults.synchronize()` перед `WidgetCenter.shared.reloadAllTimelines()`. Это принудительно синхронизирует состояние памяти с диском, гарантируя актуальность данных для виджета.

### 6. SwiftUI List: removal-анимация, render-transform, main-thread I/O

Цепочка из трёх связанных граблей при анимации удаления/слияния строки в `List` (история Voice). Подтверждено Perplexity-ресёрчем (3 независимых прогона) + наблюдением на устройстве.

**`List` игнорирует `.transition()` на своих строках.** Это архитектурное ограничение, не баг: `List` (поверх `UITableView`) перехватывает lifecycle строки при удалении из данных и форсит **свою** removal-анимацию; любой `.transition(.move/.scale)` на контенте строки молча отбрасывается. Симптом: кастомная анимация «не работала, выглядела точно так же как раньше». В `ScrollView + LazyVStack` `.transition()` работает — но туда мы не ушли (см. ниже про скролл).

**`scaleEffect`/`offset`/`opacity` — render-only, НЕ reflow'ят layout.** Это пост-layout трансформы композитора (как `CATransform3D`). Логическая высота строки в глазах `List` не меняется всю анимацию → соседние строки **стоят на месте** и прыгают только в самом конце, когда данные реально удалены. Симптом: «блок уменьшается, но остаётся пустое пространство, соседи не сдвигаются, дёргается в конце». Попытка «схлопнуть высоту» через `scaleEffect(y: 0.001)` дыру не закрывает — масштаб визуальный, ячейка держит высоту.

**Решение — two-phase, reflow отдать нативному `List`.** Фаза 1: короткий (~0.16с) render-only эффект ухода строки (fade + малый offset к соседу), НЕ попытка collapse'а высоты. Фаза 2: коммит удаления/слияния в данные `withAnimation` — и **родное** `UITableView`-removal `List`'а само плавно сдвигает все строки ниже в одном согласованном движении. Принцип: не борись с reflow контейнера, дай ему его собственную анимацию удаления, а кастом ограничь «уходом» строки. Анимировать живую `.frame(height:)` строки внутри `List` — ненадёжно (ячейка ресайзится рывками), ScrollView+LazyVStack надёжнее, но тянет за собой скролл-баг ниже.

**Стартовый лаг анимации 0.5-1с = синхронный диск-I/O на main thread.** Симптом: между тапом «объединить» и началом анимации интерфейс замирал на полсекунды-секунду. Корень: `mergeDirectional` конкатенирует два `.wav` PCM + переписывает JSON, `loadAll()` перечитывает — всё синхронно через `ioQueue.sync` на `@MainActor`. SwiftUI планирует первый кадр анимации, но следующая же работа на main thread (блокирующий I/O) выполняется **до** того как runloop успеет закоммитить кадр → фриз ровно на старте. Фикс: тяжёлую работу в `await Task.detached(priority: .userInitiated) { … }`, на main actor вернуться только для публикации `@Published history` (внутри `withAnimation`). Плюс haptic-генератор `prepare()` заранее (`onAppear`/перед использованием) — первый `notificationOccurred` без prepare добавляет ~200мс Taptic Engine cold-start синхронно на тот же thread. Первый кадр теперь рендерится на следующем vsync (~8мс), I/O невидим.

**Haptic молчит во время записи — iOS глушит app-haptics в AVAudioSession recording-режиме (НАСТОЯЩАЯ причина, не cold engine).** Симптом был **асимметричный** и потому увёл по ложному следу на ДВЕ итерации: при раскрытии long-панели вибрации нет, а при нажатии ✕/■ в той же панели — иногда есть. Корень — **`setAllowHapticsAndSystemSoundsDuringRecording` по умолчанию `false`**: пока сессия в recording-категории (`.playAndRecord` с активным движком), iOS **подавляет все haptics приложения и системные звуки**. Long-панель существует ТОЛЬКО во время живой long-записи → её expand-buzz всегда бил в этот mute. ✕/■ иногда срабатывали лишь потому, что они ЗАВЕРШАЮТ запись, и их импульс гонится с тем, как mute снимается на деактивации. `mergeHaptic` в истории «работал из коробки» НЕ из-за retained-инстанса, а потому что **в History записи нет** — mute не активен. Решение (одна строка): `try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)` в `AudioSessionManager.activate` (единственная точка активации always-active сессии; флаг сбрасывается в `false` только на деактивации, так что ставим там же). Подтверждено external-research (Perplexity, search-mode): при AV-записи haptics подавлены до этого opt-in — это пункт, который мы пропустили, гоняясь за движком.

⚠️ **Две ложные гипотезы, которые мы отвергли (чтобы следующая сессия не повторяла) — обе НЕ были причиной silent-buzz здесь, хотя сами по себе верны:**
- **Cold Taptic Engine.** «Первый импульс на холодном движке глохнет» — реальный эффект (см. merge-лаг выше), и `prepare()` его лечит. НО тут движок был тёплым (юзер только что тапал по экрану), а buzz всё равно молчал → не это. `prepare()` оставили как defensive latency-warming, не как фикс.
- **`let`-vs-`@State` для генератора.** SwiftUI `View` — value-type, пересоздаётся на каждом `@Published`-апдейте (а `RecordingCoordinator` во время записи публикует пачками — таймер/WS/LA), и plain `let gen = UIImpactFeedbackGenerator()` ре-инициализируется холодным на каждом rebuild'е; переживает только `@State`. Это корректное общее правило (для гонок prepare/fire в часто-ребилдящейся вью держи генератор в `@State`), и мы перевели на `@State` — но в ДАННОМ баге это было не при чём: глушил recording-mute, а не подмена инстанса. Перепутать легко: оба дают «buzz молчит». Дифф-диагностика: **если вибрация молчит ИМЕННО во время активной записи, а в не-записывающих экранах работает — это recording-mute, а не engine/инстанс.** Сначала проверь `setAllowHapticsAndSystemSoundsDuringRecording`, потом уже cold-start/`@State`.

**`onChange`/`onDisappear` на условно-удаляемой вьюхе не срабатывает на falling-edge.** Соседняя засада из той же сессии: long-панель reset'ила `longPanelExpanded = false` через `.onChange(of: isLongRecording) { if !active … }`, повешенный **на саму панель**. Но панель рендерится `if recorder.isLongRecording` — на falling-edge SwiftUI удаляет поддерево, и onChange для ЭТОГО же перехода не доставляется надёжно (обработчик висит на размонтируемой вью). Итог: стейт `true` протекал в следующую запись — «панель стартует уже раскрытой». Решение: вешать reset на **стабильного предка** (корневой ZStack, всегда в дереве) и реагировать на **rising-edge** (`if active { …=false }`), а не пытаться поймать teardown удаляемого поддерева. Правило: **modifier'ы жизненного цикла, которые должны отработать на исчезновение условного блока, нельзя вешать на сам этот блок — только на родителя, который переживает оба состояния.**

**iOS 18/26: кастомный `DragGesture` на строке `List`/`ScrollView` убивает вертикальный скролл.** Подтверждённый Apple-баг (FB14688465, открыт с Xcode 16), на iOS 26 **усугубился** — `.simultaneousGesture` перестал работать вовсе, gesture arbitration переписан. Единственный надёжный обход для кастомного свайпа — `UIGestureRecognizerRepresentable` + `gestureRecognizerShouldBegin` (фильтр по горизонтальной скорости + edge-guard), либо уход на `ScrollView + LazyVStack` с `DragGesture(minimumDistance:)` + guard `abs(dx) > abs(dy)`. Поэтому кастомный свайп-reveal (круглые вертикальные кнопки) был прототипирован на ScrollView и **откатан** на нативный `List` + `.swipeActions` ради надёжности скролла — см. `methodology/переносимый-дизайн.md::Нативный компонент vs кастом`.

**Что пробовали (graveyard):**
- `.transition(.move/.scale)` на строке `List` — молча игнорируется (ограничение `List`).
- `scaleEffect(y: 0.001, anchor:)` для «схлопывания высоты» — render-only, оставляет дыру, соседи не едут.
- `DispatchQueue.main.asyncAfter` + синхронный I/O в коммите — тот самый стартовый фриз.
- Кастомный свайп с круглыми вертикальными кнопками на `ScrollView+LazyVStack` — работал, но требовал ручной возни с шириной панели и порогом full-swipe; откатан на нативный.
- Full-swipe-to-delete с растущей красной зоной и haptic-«защёлкой» на 50% — прототип рабочий, но native `.swipeActions` его не даёт (только кастом), а в native delete-кнопке при full-swipe label НЕ растягивается (иконка едет влево, центр пустой) — текст «Удалить запись» по центру там показать нельзя без полного кастома.

### 7. iOS 26 keyboard notifications и SwiftUI composer desync

**Симптом**: в AI Chat input то отстаёт от клавиатуры на раскрытии, то при закрытии
«зависает» наверху на долю секунды; в другой итерации input оставался под клавиатурой.
По ощущениям это выглядит как «клавиатура живёт своей анимацией, а composer своей».

**Причина**: на iOS 26 keyboard notifications не дают удобный SwiftUI-ready контракт.
В логах реального устройства приходила приватная animation curve `7` с duration около
`0.383` на open, а на hide `keyboardWillChangeFrame` мог приходить уже как финальное
событие с `duration=0`. Обычный fallback `.easeOut(duration:)` на private curve заставлял
composer ехать медленнее клавиатуры; ожидание финального hide frame оставляло dock наверху
до позднего state update. Поздний `keyboardWillHide` тоже не спасает app-owned close: в
реальных логах он приходил уже после финального frame и с `priorHeight=0`, когда вычислять
плавный collapse было поздно. Отдельная ловушка: считать высоту через SwiftUI reader view
или safe-area push нельзя — reader может иметь не тот bounds, а safe-area обновляется не в
фазе keyboard movement.

**Решение**: считать keyboard overlap в координатах `window.bounds` (`window.convert(endFrame,
from: screen.coordinateSpace)` + intersection), хранить baseline bottom inset только когда
keyboard hidden, а сам composer двигать overlay-`offset`, не reflow'ить transcript. Для
private curve `7` на open использовать front-loaded timing, чтобы dock стартовал вместе с
клавиатурой. Для app-owned hide не ждать системного notification: `dismissKeyboard()` сначала
запускает proactive collapse (`0.160s`, строка лога `collapse reason=dismissKeyboard`), затем
снимает focus; `keyboardWillHide` остаётся страховкой для внешних системных путей закрытия.
Логи `[Keyboard]` должны писать `frameEnd/inWindow/safeBase/height/lift/curve/anim/willHide`,
`collapse reason=...` и отдельный `input tap`, иначе нельзя отличить геометрию, timing и
перехват touch. Конкретная реализация и UX-модель — `fact-voice-chat-tab.md::Composer keyboard`.

**Что пробовали и почему не сработало**: чистый `.ignoresSafeArea(.keyboard)` + padding по
safe area сдвигал историю и давал рассинхрон; `keyboardWillChangeFrame` без `willHide` не
ловил начало закрытия; обычная `.easeOut` для `curve=7` выглядела нормально на hide, но
заметно отставала на open; Reddit/GPT research не дал готовой нативной константы для
private curve `7`, только подтвердил направление диагностики (`keyboardWillChangeFrame`,
`inputAccessoryView`, `UIKeyboardLayoutGuide`). Следующая ступень, если iOS 26 снова изменит
контракт, — UIKit `UIKeyboardLayoutGuide` или `inputAccessoryView`, не очередной слой SwiftUI
padding.

### 8. Build database disk I/O error после прерванного билда

**Симптом**: `./deploy.sh` падает пачкой `error closing '.../Objects-normal/arm64/<File>.o' ... No such file or directory` + финальное `accessing build database "...XCBuildData/build.db": disk I/O error`. Выглядит как катастрофа компиляции, но ни одной реальной ошибки в коде нет.

**Причина**: прерванный предыдущий билд (Ctrl-C, убитый процесс, прерванный деплой) оставил `XCBuildData/build.db` (SQLite) в несогласованном состоянии. Последующие билды не могут открыть базу.

**Решение**: удалить `XCBuildData`, билд пересоздаст её с нуля:
```bash
rm -rf build/DerivedData/Build/Intermediates.noindex/XCBuildData
```
Полную `DerivedData` сносить не нужно — достаточно build-базы. Не путать с нехваткой места (`fact-xcode-disk-usage.md`) — тут база битая, а не диск полный.

### 9. Terminal navigation jank: SwiftUI snapshots не спасли, сработал UIKit-owned container

Симптом снаружи выглядел обманчиво простым: всего 16-17 карточек вкладок на iPhone 15 Pro,
но переходы `projects → project tabs` и back-свайпы давали `worst=70-100ms`, иногда экран
дёргался, preview назад не двигался под пальцем, scroll проектов то сбрасывался при клике, то
восстанавливался после back, а первый tap/scroll после перехода мог не сработать. Важное
наблюдение: это происходило и при `cachedTabs=true fresh=true skip tabs reload`, то есть не
сеть, не cache miss и не `/tabs` payload были главным корнем.

Диагностика стала полезной только после разделения сигналов. `MainThreadWatchdog` ловит
реальные hangs, но молчит на обычном frame-budget miss; значит 70-90ms в `[frame]` — не
обязательно "main завис", а часто commit/render/layout. `FrameMonitor` с фазами
`mount/animate/swap/settle` показывает, где именно платится кадр. `TerminalPerfContext` с
`nav#` нужен, чтобы не привязать соседний HTTP-log к неправильному переходу. `TerminalRenderProbe`
помог снять гипотезу "всё штормит body": когда `row bodies` совпадали с числом строк без
повторов, проблема была ниже — в moving surface/layout/compositor, а не в бесконечной
пересборке строк.

Что было проверено и почему это не финальное решение. Deferred prefetch/reload уменьшил
плохие публикации в хвосте перехода, но не объяснил лаг при fresh cache. Удаление системного
`NavigationStack` toolbar убрало часть Liquid Glass/nav-bar churn и симптом с двоящимся
header, но project→tabs всё ещё лагал. SwiftUI value snapshots и lightweight rows доказали,
что live rows/controls тяжёлые, но сами snapshots оставались SwiftUI-деревом в движущемся
контейнере. Grey skeletons сделали субъективно плавнее, но это неприемлемый UX как постоянная
маска перехода: пользователь должен видеть реальные вкладки, если они уже cached. Bitmap
overlay/`UIImageView` ускорял отдельные кадры, но дал более опасные визуальные гонки: forward
телепортировал экран, back показывал не тот preview, текущая страница ехала поверх себя, а
store selection/live layer/cached bitmap жили в разных фазах.

Финальное решение — не чинить ещё один restore/snapshot, а перенести ownership границы
`projects/tabs/chat` в UIKit. `TerminalUIKitNavigationController` держит постоянные shells
`projectsShell`, `tabsShell`, `chatShell`; projects/tabs — `UITableView` controllers, chat —
один hosted SwiftUI controller. Push ставит destination shell справа и двигает transform,
interactive back двигает source shell по raw translation пальца, `viewDidLayoutSubviews` не
переукладывает shells во время transition. Scroll offsets живут в UIKit table view, store
anchors остаются backup'ом, а не единственным механизмом удержания позиции. После этого логи
стали вида `label="uikit pushProject..."`, `dropped=0`, `worst≈17-22ms` на обычном push, а
пользователь подтвердил быстрый forward/back без skeleton-transition.

Loader/preloader после этого разделены по смыслу. Skeleton cells в UIKit projects/tabs lists
показываются только при первой холодной загрузке, когда данных вообще нет. Cached rows
показываются сразу; stale reload и prefetch ждут quiet-window и не сбрасывают scroll. Activity
на project row рисуется ring-loader + count из агрегированного project activity; если project
count показывает `1`, но ring не крутится, смотреть надо не навигацию, а источник
`CTActivitySummary.streaming`.

Правило на будущее: не возвращать Terminal boundary на SwiftUI `.offset`/snapshot/bitmap
overlay, пока требование — интерактивный "как книжка" back gesture + стабильный vertical
scroll. Для таких экранов root gesture и vertical scroll должны принадлежать одному
platform-owned container. SwiftUI внутри ячейки/детали допустим, но не как moving root tree.
Если снова появятся `worst=70-90ms` при `uikit ...` labels, сначала смотреть
`[term-swipe-geo]` и layout-reset/gesture ownership; если labels снова `bitmap` или
`term-nav pushProject` без `uikit`, значит тестируется старый путь.
