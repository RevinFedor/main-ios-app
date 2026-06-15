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

### 9. Terminal navigation jank: не main-thread, не строки, а commit/render поверхности

**Симптом**: переходы `projects → project tabs → chat` и back-свайпы в Terminal визуально
дёргались. Сначала пара переходов могла быть плавной, потом лаг появлялся; если подождать
5-10 секунд, часть back-переходов становилась нормальной. На больших чатах отдельный симптом
был жёстче: при открытии или возврате из вкладки приложение могло зависнуть на сотни мс или
секунды, хотя сеть уже ответила.

Диагностика сработала только когда появились три независимых наблюдателя. Main-thread
watchdog пинговал main с фоновой очереди и ловил реальные блокировки (`[hang]`); он молчал
на обычных 44-79ms slide-hitch'ах, значит это не полный main hang. CADisplayLink
`FrameMonitor` видел предъявленные кадры и фазировал окно на `mount/animate/swap/settle` —
это отделило render-server/commit hitch от движения offset'а. `TerminalRenderProbe` считал
body eval строк (`row bodies/distinct`); когда bodies совпадали с числом строк без повторов,
гипотеза "штормит весь список" отпала. `OpsRegistry` и `TerminalPerfContext` добавили
`inFlight`, `lastOp` и `nav#`, чтобы не путать nearby network log с причиной кадра.

Что оказалось не причиной. Prefetch действительно мог попадать в окно анимации, поэтому его
припарковали, но это не объясняло постоянный `commit≈77-95ms`. `.drawingGroup()` на moving
layers дал чёрный ScrollView и не уменьшил dropped frames — значит причина не "слишком много
пикселей каждый кадр". Snapshot-cover поверх живого экрана сделал хуже: коммит всё равно
платится под обложкой, плюс обложка добавляет ещё один render. Off-main normalize/history
нужен, но если после него остаётся 12s freeze, это уже не парсинг, а layout гигантского
`Text` в одном row. `activeOps=0` тоже не доказывает idle — нужен recent/last op контекст.

Первый большой корень был системный navigation bar. Все три Terminal-level'а жили внутри
одного shared `NavigationStack`, но каждый объявлял свой `.toolbar` и
`.toolbarBackground(.visible)`. При custom `.offset`-slide SwiftUI не делает настоящий
push/pop, но всё равно пересобирает iOS 26 Liquid Glass nav-bar chrome на swap уровня.
Фазовые логи показали тяжёлые кадры в `commit/swap`, а не в `animate`; `toolbarBackground`
DIAG улучшал только случаи с похожими header'ами; визуальный симптом "gear/hamburger
двоится на кадр" совпадал с двумя nav bar chrome. Фикс: убрать системный toolbar из этих
трёх уровней, поставить custom `TerminalHeaderBar` и `.navigationBarHidden(true)`.

Второй оставшийся корень — project→tabs transition surface. Свежие логи после toolbar-fix:
`pushProject ... cachedTabs=true fresh=true skip tabs reload`, но `worst=44-59ms` в
`animate/commit`. Это уже не сеть и не `loadTabs`; тяжёлым оказался сам moving tabs-list:
`ScrollView + TerminalTabRow + AgentIconView + glass refresh + contextMenu/FAB` даже на
3-10 строках. Текущий mitigation: forward project snapshot рендерит lightweight rows без
ScrollView, asset lookup, spinner, glass-refresh и floating controls; live tabs view во
время `interactionsSuspended` тоже сначала показывает дешёвый список, а полные controls
появляются в `settle`. Следующий лог должен проверять именно фазы: если дорогой кадр остался
в `animate` — moving surface всё ещё тяжёлая; если ушёл в `settle` — навигация чистая, а
интерактивные controls дорисовываются после неё.

Отдельный фикс для history: публикация загруженной истории не имеет права попадать в back
transition. Старый guard содержал `|| historyLoading.contains(tabId)` и поэтому никогда не
дропал publish для вкладки, с которой пользователь уже ушёл; 250 entries могли переписать
`entriesByTab` во время следующего экрана. Сейчас история нормализуется в `Task.detached`,
публикуется только если tab всё ещё selected, а при активной навигации пишет
`history publish WAIT interaction` и после ожидания либо публикует, либо `DROP after wait`.
Именно это объясняет свежий пользовательский результат: "во время подгрузки чата лагов нет,
перехожу в чат, возвращаюсь обратно — лага нет".
