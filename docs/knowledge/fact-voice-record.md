# Voice Record subsystem

Голосовой ввод — вторая основная подсистема приложения (помимо habit-tracker'а). Soniox WebSocket стриминг с микрофона, on-device transcript history, AppIntents для Shortcuts/Action Button, Live Activity на Dynamic Island.

## Tabs: Voice (default) · Remote · Habits

`RootTabView` показывает три вкладки в порядке Voice → Remote → Habits, default selection `.voice`. Habit-виджет на home screen использует `widgetURL("habittracker://habits")` и `TabRouter` принимает оба `"habits"` (new) и `"home"` (legacy, для уже установленных старых widget'ов). При tap из Control Center / Shortcut / Live Activity action — auto-switch на Voice через flag `wantsVoiceTab` в App Group.

**Почему Voice default.** Это самая частая точка входа юзера; Habits открывается явно через виджет или вкладку. Remote — встроенный браузер к custom-terminal mobile-web, см. `fact-remote-tab.md`.

## Coordinator phases

```
.idle → .starting → .recording → .stopping → .idle
                ↘ .ended (live activity grace window)
```

`RecordingCoordinator` единственный owner: `DictationSession` (WS), `RecordingActivityManager` (Live Activity), `TranscriptStore`. Все phase transitions идут через него; UI и Live Activity подписаны на `@Published phase`.

## Soniox WebSocket stop deadlock

**Симптом:** юзер нажал Stop, лог показывает `[Dict] stop() — entered, stopped=false wsOpen=true` и дальше тишина. App висит в `.stopping` бесконечно, Live Activity показывает "Stopping…", finalize-frame не отправлен.

**Корень:** `try await task.send(.data(Data()))` (async вариант `URLSessionWebSocketTask`) **deadlock'ит** на degraded WS connection. Apple-API ждёт flush-confirmation которая никогда не придёт когда socket в полу-сломанном состоянии (background suspension, broken pipe). Async-вариант выглядит safer, но именно он залипает; completion-handler вариант fire-and-forget.

**Решение:** `task.send(.string("")) { error in ... }` + 60s hard-cap через `Task.sleep` (НЕ `DispatchQueue.main.asyncAfter` — main queue замораживается когда app suspended в background, и watchdog никогда не сработает).

```swift
// Hard-cap: если Soniox не закрыл сам через 60с — force-fire stopped.
forceStopTask = Task { [weak self] in
    try? await Task.sleep(nanoseconds: 60_000_000_000)
    guard !Task.isCancelled, let self else { return }
    await MainActor.run {
        guard !self.stoppedFired else { return }
        self.wsTask?.cancel()
        self.cleanup()
        self.fireStopped()
    }
}
```

## Stop & finalize lag: empty TEXT frame, 60s hard-cap, lastFinalEndMs

**Симптом ранее:** запись длиннее ~30с, юзер нажал Stop → транскрипт обрезан примерно на 30-секундной точке. PCM (`.wav`) при этом полный, reload из истории даёт верный полный текст. То есть аудио в порядке, потерян именно **live finalize tail**.

**Корень 1 — frame opcode.** Soniox `stt-rt-v4` end-of-stream signal — **пустой TEXT frame** (`task.send(.string(""))`, opcode 0x1). До правки слали `task.send(.data(Data()))` — пустой **BINARY** frame, opcode 0x2. Soniox его silently игнорирует. В результате finalize не запускается, остаток is_final tokens не выдаётся, `{finished:true}` не приходит. Соединение тянется до нашего hard-cap'а, который убивал WS и шипал обрезанный transcript.

**Корень 2 — слишком короткий watchdog.** Параллельно был 2с hard-cap. Soniox endpoint detection на плотной речи держит коммиты до паузы — лаг между «аудио отправлено» и «is_final пришёл» легко 20-30 сек. 2с рубило соединение до того как Soniox успевал отдать хвост.

**Корень 3 — recvLoop выходил по `stopped`.** `while !stopped` в recvLoop'е после вызова `stop()` (где мы ставим `stopped = true`) на следующем витке выходил из цикла. Tokens продолжали приходить из Soniox после нашего finalize, но мы их уже не слушали.

**Фикс (порт voice-record `fix-history-archive.md::Шрам #17 Re-fix`).**

1. **`task.send(.string(""))`** вместо `.data(Data())`. См. Soniox docs: *«Send an empty WebSocket frame... an empty string signals end-of-audio.»*
2. **Hard-cap 60с** (`stopHardCapSeconds`). Срабатывает только на реальный WS-hang (network split в момент drain). Нормальное finalize в 20-30с проходит свободно.
3. **`while true` в recvLoop**, выход только по throw на socket close. Иначе мы пропускали финальные is_final tokens.
4. **`lastFinalEndMs` tracking.** В каждом is_final token парсим `t.end_ms`, держим максимум. `lagSeconds = recordedSec - lastFinalEndMs/1000` — точная метрика «сколько секунд Soniox нам ещё должен».
5. **`{finished:true}` parsing.** Это последнее сообщение Soniox перед закрытием socket. Логируем для диагностики (`final_audio_proc_ms`, `total_audio_proc_ms`). Мы НЕ закрываем WS сами на lag≈0 — ждём естественного close, потому что endpoint-detection буфер может ещё дотечь.
6. **Mic stop сразу в `stop()`.** `engine.inputNode.removeTap` + `engine.stop()` происходит до того как мы начинаем ждать WS finalize. Аудио, записанное **после** нажатия Stop, не уходит ни в Soniox, ни в `.wav`.

**UI tail-индикатор.** Делегат `dictation(_, didUpdateStoppingLagSeconds:)` тикает каждые 250мс из `stoppingProgressTimer`, прокидывается в `Coordinator.stoppingLagSeconds` (`@Published`). `VoiceRecordTabView.toolbarTitle` в `.stopping` показывает `Finalizing · 28s tail` — лаг тает в реальном времени, юзер видит что finalize в работе, не висит.

**Coordinator safety timer.** `RecordingCoordinator.stop()` ждёт `didStopWith` через `withCheckedContinuation`. Safety-таймер поднят с 4с до 65с (на 5с выше DictationSession's 60с hard-cap) — primary resumer всегда didStopWith, safety только на катастрофический stall.

**Background-intent совместимость.** `LiveActivityIntent.perform()` await'ит `Coordinator.stop()` → `DictationSession.stop()` → wait. AppIntents даёт generous execution assertion на время async perform() (нет жёсткого 10с лимита для LiveActivity intents). Транскрипт доставляется в Shortcut через `ReturnsValue<String>` после resume continuation — pipeline целиком.

**Лог-маркеры здорового и сломанного поведения** идентичны voice-record:
```
# Здоровое:
[Dict] stop() — entered, ... recorded=18.7s lastFinalEnd=13.8s lag=4.9s
[Dict] soniox finished:true (final_audio_proc_ms=4920 total=4980ms lag=0.0s)
[Dict] fireStopped — emitting pcm=... lag=0.0s
[Coord] stop() — returned

# Сломанное (старый 2с watchdog или binary frame):
[Dict] stop() — entered, ... lag=4.9s
                          ← (тишина 2с)
[Dict] stop() — hard-cap watchdog fired (2s) lag=4.9s   # хвост 4.9с потерян
```

**Connect-watchdog тоже на `Task.sleep`, не на main queue.** Симптом из той же серии: «всё пишется в буфер, стриминг не начинается» — `connectSoniox` залип где-то между mint и `wsOpen=true`, а 10с connect-watchdog не стрелял. Корень тот же что у stop hard-cap: watchdog был `DispatchQueue.main.asyncAfter`, но `try await task.send(configStr)` внутри самого `connectSoniox` мог заблокировать main runloop — и watchdog, запланированный на ту же очередь, не получал слот. Фикс: watchdog переведён на `Task { try await Task.sleep }` (независим от main), арм'ится **до** сетевых вызовов, плюс 8с `timeoutInterval` на mint-запрос. Диагностические лог-маркеры на каждом шаге локализуют точку залипа без дебаггера: `[Mint] begin → POST → ← HTTP` (mint), `[Dict] ws task.resume() → ws config sending → sent → ws OPEN` (handshake). Отсутствие следующего маркера = точка залипа.

## Cold-launch policy: два разных пути в зависимости от entry point

Recording intents разные по требованиям. Control Center widget (`ToggleVoiceRecordingIntent: SetValueIntent, AudioRecordingIntent`) и Action Button через AppShortcuts (`ToggleVoiceRecordingShortcutIntent`) сейчас идут разными путями:

**Control Center widget — `openAppWhenRun = true`** (классический подход). `AudioRecordingIntent` сам по себе не пробуждает app на iOS 26 при force-quit состоянии: `perform()` крутится в widget process, `pendingAction` пишется в App Group, но host app не поднимается пока юзер не откроет иконку. Лог в шраме:
```
[12:34:22] [Intent] Toggle perform()       ← в widget extension
[12:34:25] [Coord] init                     ← +3 секунды, ТОЛЬКО потому что юзер открыл app
```
Apple DTS engineer Ed Ford в Developer Forums thread 761677 утверждал обратное, но на iOS 26 это не работает. `openAppWhenRun=true` даёт brief foreground flash и app поднимается. Trade-off принят.

**Shortcuts.app / Action Button — `AudioRecordingIntent + LiveActivityIntent` dual conformance** (см. секцию «Killed-state Toggle» ниже). `openAppWhenRun=true` для этого пути убран в пользу dual-conformance.

**Что пробовали и не сработало:**
- Только `AudioRecordingIntent` без `openAppWhenRun` — не пробуждает app на iOS 26 (для Control Center widget).
- `SetValueIntent + AudioRecordingIntent` без `openAppWhenRun` — FB14357691 (LNActionExecutorError 2018), perform() вообще не запускается на iOS 18.x.
- `continueInForeground(alwaysConfirm: false)` (iOS 26 API replacing openAppWhenRun) для Shortcut Toggle — формально поднимает app, но **только на время `perform()`**. Когда perform возвращается, iOS видит «нет foreground UIScene, AVAudioSession ещё не активна (WS connect занимает ~2с)» и через 15с убивает процесс. Подтверждено наблюдаемым reap-таймером 15s после continueInForeground при killed-state cold-launch.

## Killed-state Toggle: LiveActivityIntent + AudioRecordingIntent dual conformance

**Симптом:** force-quit app → tap Toggle через Shortcut/Action Button → app поднимается, Activity создаётся, **но через 15 секунд процесс убит**. WS connect (1.7с к Soniox) не завершился, AVAudioSession не активирована, рекординг не идёт.

**Корень.** Apple docs: *«If you adopt the LiveActivityIntent or AudioPlaybackIntent protocol, the system runs the app intent in the app's process.»* `AudioRecordingIntent` — маркер-протокол: system понимает что действие про recording (для discoverable «audio» background mode), но **не гарантирует** что perform() исполняется в host process и не продлевает lifetime. `LiveActivityIntent` даёт обе гарантии (in-process + keeps process alive while Activity is live) + foreground-equivalent token для `Activity.request()` из этого perform() (см. `fact-live-activity.md::Persistent .idle mode [deprecated]`).

`UIBackgroundModes=audio` сам по себе **не** удерживает процесс — Apple дословно: *«as long as it is playing audio or video content or recording audio content»*. Ключевое слово — *while*. Пока `AVAudioSession.setActive(true)` не сделана, assertion не engaged, процесс reapn'ется.

**Решение** для `ToggleVoiceRecordingShortcutIntent`: dual conformance + wait-for-phase loop в perform(). На start ждём `.recording`, на stop ждём `.idle`. AppIntents framework сам даёт execution assertion на время async perform() — никаких ручных `beginBackgroundTask` (см. graveyard ниже).

**Что perform() ВОЗВРАЩАЕТ — критично для clipboard в фоне.** Тип результата — `some IntentResult & ReturnsValue<String>`. На stop возвращаем накопленный транскрипт; на start пустую строку. Это единственный iOS-26-safe способ положить текст в системный clipboard из background-launched intent (см. `fix-background-intent-crashes.md::Background clipboard`). Юзер собирает Shortcut «Toggle Voice Record → Copy to Clipboard» в Shortcuts.app: наш intent возвращает строку, Shortcuts pipe'ит её в стандартный action «Copy to Clipboard» который пишет pasteboard с system privilege. **Без** этого pipeline `UIPasteboard.general.string = ...` из background-intent контекста silently no-op.

**Deactivate AVAudioSession на stop-пути.** Перед возвратом из perform() при stop — `AVAudioSession.setActive(false, options: [.notifyOthersOnDeactivation])`. Без этого процесс получает SIGKILL через 2-7с после return (jetsam watchdog `0x8badf00d` за удержание active recording session в suspend). Цена — ~1с дыра в фоновой музыке (hardware Bluetooth route reconfig). Точка решения о deactivate — в `RecordingActivityManager.end()` через флаг `stopOriginatedFromIntent` который ставит `RecordingCoordinator.handlePendingActionIfNeeded`. In-app stop через UI-кнопку (`toggle()`) не идёт через `handlePending` → флаг false → no deactivate → no music gap. Подробно — `fix-background-intent-crashes.md::Jetsam 0x8badf00d`.

**Что пробовали (graveyard):**
- `openAppWhenRun=true` для Shortcut Toggle — работало, но открывало UI на каждый tap.
- `continueInForeground(alwaysConfirm: false)` (iOS 26 supportedModes) — формально успешен, но reap через 15с потому что perform() возвращался до AVAudioSession.setActive(true).
- Fire-and-forget `handlePendingActionIfNeeded` без wait-for-phase — reap до WS connect.
- Ручной `beginBackgroundTask` + `endBackgroundTask` в defer'е — race с system process-suspension logic, AppIntents framework УЖЕ держит assertion на время async perform(). Дубль assertion'ов → крах при возврате из perform().
- `IntentResult & ProvidesDialog` с empty dialog — Apple показывает Siri-style banner с Done-кнопкой на Action Button. Юзер отверг UX.
- Conditional `setActive(false)` (только при cold-launch detection через timestamp в App Group / scene-state check) — `applicationState` ненадёжен в Intent контексте (LiveActivityIntent.perform поднимает scene в `.active` даже без видимого UI), live-process путь оставался незащищён → SIGKILL через 3-7с. Финальная стратегия: **любой** intent-stop ВСЕГДА deactivate'ит, in-app stop НИКОГДА не deactivate'ит. Развилка по `stopOriginatedFromIntent` флагу, а не по applicationState.

## AppShortcutsProvider должен быть в main app target

**Симптом:** юзер ищет «Habit» в Shortcuts.app при добавлении нового shortcut — действия появляются, **но при попытке добавить помечаются как «Неизвестное действие / Данное действие не удалось найти в этой версии приложения»**. Через Control Center widget button те же intents работают.

**Корень:** `VoiceRecordShortcuts.swift` (с `AppShortcutsProvider` conformance) лежит в `HabitWidget./` папке. Виджет использует `PBXFileSystemSynchronizedRootGroup` — файл автоматически включается в widget extension target. **Но Shortcuts.app сканирует AppShortcutsProvider только в main app target.** В widget extension он невидим для Shortcuts metadata-scanner.

**Что пробовали:**
1. Reinstall app, reboot iPhone, переустановка через `./deploy.sh` — Shortcuts metadata кеш не сбрасывается.
2. Открыть app один раз перед открытием Shortcuts — не помогает, потому что провайдер просто не зарегистрирован в main process.

**Решение:** добавить explicit reference в `HabitTracker` target (`PBXBuildFile` + `PBXFileReference` + Sources phase) **и** exception в `PBXFileSystemSynchronizedBuildFileExceptionSet` для widget target — чтобы файл не компилировался дважды (иначе duplicate `AppShortcutsProvider` linker error).

## Toggle shortcut: state-aware из App Group

`ToggleVoiceRecordingShortcutIntent.perform()` читает `VoiceRecordConfig.SharedKeys.isRecording` из App Group и решает start/stop. Никакого «file-flag» / «note-state» / iCloud-trick не нужно (распространённая ошибка — городить переключение через файл-флаг в Notes). State в App Group — единственный источник правды.

## Dev mode reactivity: @AppStorage в обеих View

**Симптом:** юзер toggle'нул "Developer mode" в Settings → закрыл sheet → ⌥ иконки в navbar не появились. Чтобы появились — нужно swipe Voice→Habits→Voice (tab bounce).

**Корень:** Settings sheet писал через `@State + UserDefaults.set + synchronize()`. VoiceTab читал через `@AppStorage`. У `@AppStorage` встроенный observer на `NSUserDefaults.didChangeNotification`, но он подписывается на **свой** instance `UserDefaults(suiteName:)`. Manual `.set()` через **другой** instance того же suite — не триггерит уведомление в первой View внутри того же процесса (iOS quirk).

**Решение:** обе View используют **`@AppStorage` с одним и тем же store**. Никаких `@State + manual UserDefaults.set`. При binding-write через `@AppStorage` оба observer'а получают update моментально.

## Mic-picker на главном Voice

Toggle "Always use iPhone microphone" перенесён из Settings в `MicSourcePicker` справа от big mic button. Picker показывает **текущий активный микрофон real-time** (`AVAudioSession.routeChangeNotification` observer), при tap выпадает Menu со всеми available inputs + toggle "Только iPhone-микрофон" с lock-badge.

`AudioSessionManager.probeInputs()` вызывается в `.onAppear` — без активной session iOS не публикует AirPods в `availableInputs`, picker показывал бы только built-in.

## Provisioning expiry counter

`ProvisioningInfo.swift` парсит `Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")`, slice'ит embedded plist между `<?xml` и `</plist>` маркерами (CMS-wrapper нельзя через `String(data:encoding:)` из-за binary bytes), извлекает `ExpirationDate`. `ProvisioningExpiryView` показывает days remaining (зелёный/оранжевый/красный по близости истечения) в обоих Settings sheets (Voice + Habit).

**Почему не сохраняем install date.** Free-Apple-ID profile живёт ~7 дней с момента выпуска через `xcodebuild -allowProvisioningUpdates`, не с момента install. Provisioning ExpirationDate — источник правды.

## Log counter рядом с copy-button

В dev-mode navbar показывает `<copy-icon> <N>` где N = количество строк в текущем `VRLog` файле. Обновляется через `Timer.publish(every: 1)` пока view on screen, при `clear` снимается в 0, при `copy` пересчитывается.

`VRLog.lineCount()` считает raw `\n` байты (`reduce + count of 0x0A`) — дешевле чем split, и достаточно для индикатора «лог рос с последней очистки».

## История: карточка, табы, статус-заметка, объединение

Экран истории (`TranscriptHistoryView`) — список `TranscriptEntry`, sorted newest-first, на `List` с нативными `.swipeActions`. Карточка (`EntryRow`) и модель прошли несколько раундов редизайна; ниже только невидимый контекст.

**Заметка — явный статус `noteFlag`, не производное от заголовка.** В модели `noteFlag: Bool?` отдельно от `title`. Раньше «заметка» выводилась из факта «есть кастомный title» — теперь это два независимых признака. Computed `isNote = (noteFlag == true) || hasCustomTitle` — обратная совместимость: записи со старым кастомным заголовком всё ещё читаются как заметки, но новый флаг позволяет пометить запись заметкой **без** переименования (и наоборот). Зачем разделили: кнопка «+Notes» даёт статус, не трогая авто-заголовок. `noteFlag` Optional + nil-default — Codable-миграция старого JSON без ключа. При merge результат = заметка если **любая** сторона была заметкой (`target.isNote || source.isNote`). Принцип — `methodology/переносимый-дизайн.md::Направленное слияние` соседствует с этим, но «статус явным полем» — само по себе модельное решение.

**Три таба сверху: `All / Voices / Notes`, дефолт — средний (`Voices`).** Segmented в navbar `.principal`. `Voices` = всё КРОМЕ заметок (`!isNote`), `Notes` = только заметки, `All` = всё. То есть как только запись помечена заметкой (+Notes или кастомный заголовок) — она уходит из Voices в Notes. Дефолт — Voices, потому что сырые расшифровки это основной поток, заметки — отобранное меньшинство. Таб `Notes` несёт счётчик `Notes (N)` — число заметок; скобки показываются только при N>0.

**Кнопка «+Notes» на главном Voice-экране** (между Copy и Share, `VoiceRecordTabView`). Переводит **последнюю** запись (`Coordinator.lastEntryId`, ставится при append в `didStopWith`, сбрасывается в `start()`) в статус заметки. Тогл: помечена → жёлтая «In Notes» с галочкой, повторный тап снимает (`setNoteFlag`). Заголовок при этом не трогается — остаётся авто-derived. `lastEntryId` сбрасывается на старте новой записи, чтобы +Notes не целился в устаревшую.

**Объединение направленное (`TranscriptStore.mergeDirectional`), НЕ хронологическое.** Прошлая версия склеивала по времени с midpoint-датой и новым id — переделано. Теперь: запись, на стрелку которой нажали — **source (вторичная)**, она дописывается в **конец** соседа; сосед по направлению — **target**, держит свою идентичность (id, title, date, позицию в списке). Текст: `target.text + "\n" + source.text` (target первым). Аудио: PCM target первым, потом source, в новый `.wav` (срезая 44-байтные заголовки); одиночный путь переиспользуется (guard от удаления). `mergeCount` — сумма (`[N]`-бейдж). Сосед резолвится из **видимого** (отфильтрованного табом) списка, не из полного `history` — под Voices заметки скрыты, и «карточка выше» на экране ≠ index−1 в `recorder.history`; поэтому View передаёт явный `targetId`, а `Coordinator.mergeEntry(sourceId:targetId:)` не пересчитывает соседа сам. Мотивация направленности — юзер выбрал явно: *«приоритет у той заметки, в которую идёт мердж; та, на которой нажал стрелку — вторична»*.

**Merge-анимация и стартовый лаг — см. `fix-ios-stability.md::SwiftUI List`.** Two-phase (короткий render-leave → коммит данных → нативное removal List сдвигает соседей) и вынос тяжёлого `.wav`-concat в `Task.detached` (иначе синхронный I/O морозил первый кадр на 0.5-1с) задокументированы там как платформенная механика.

**Свайп влево — нативный `.swipeActions`, icon-only.** Три кнопки горизонтально: Delete (у края, full-swipe удаляет), merge ↓, merge ↑. `.labelStyle(.iconOnly)` обязателен: на iOS 26 swipe-кнопка по умолчанию рисует **icon + title** (на iOS ≤18 — только icon), без явного стиля появлялись подписи. Полный цикл «кастомный свайп с круглыми вертикальными кнопками на ScrollView+LazyVStack» был прототипирован и откатан — почему остались на нативном, см. `fix-ios-stability.md` (iOS-26 баг скролла) и `methodology/переносимый-дизайн.md::Нативный компонент vs кастом`.

**Копирование — фиксированный формат, 4 строки.** Copy (кнопка-пилюля в шапке карточки + пункт контекст-меню) кладёт в буфер: строка 1 `date: YYYY-MM-DD HH:MM:SS`, строка 2 пустая, строка 3 заголовок (`displayTitle`), строка 4 текст. Формат точный по просьбе юзера (не locale-formatted). Иконка копи-кнопки в **фиксированном боксе** 16×16 — `doc.on.doc`↔`checkmark` имеют разный интринсик-размер, и без фиксации своп глифа менял высоту пилюли → строка List переизмерялась и прыгала вверх-вниз.

**Постоянное скругление карточки.** `RoundedRectangle(14)` фон + `clipShape` всегда, и `contextMenu { } preview:` той же формы. Иначе скруглённые углы появлялись только в момент long-press preview (iOS приподнимает строку со скруглением), и карточка визуально скакала из прямых углов в скруглённые. Принцип — `methodology/переносимый-дизайн.md::Постоянный affordance`.

**Редактируемый заголовок (`title: String?`).** Опционален: `nil` = деривить из текста (первые слова до ~28 символов, обрезка по границе слова + «…»). При reload/смене даты сохраняется; при merge берётся `target.title`. Иконка `note.text` на chip'е — при `isNote` (кастомный title ИЛИ +Notes-флаг). Заголовок-chip слева, дата-chip справа — кликабельные пилюли (`Capsule` 0.08), тап открывает `TitleEditorSheet` / `DateEditorSheet` (графический `DatePicker`). Карандаш-affordance убран — chip-стиль сам сигналит редактируемость.

**Свёртка превью без анимации (3 строки).** Collapsed `lineLimit = 3`, тап разворачивает. `expanded.toggle()` **без** `withAnimation`: анимация смены lineLimit заставляла `List` пересчитывать высоту строки на лету и дёргать scroll-offset. Рядом с «Show more» — число символов (`entry.text.count`), дата-chip справа внизу.

## Mic source в Live Activity

Live Activity показывает какой вход сейчас пишется — в Lock Screen / Notification Center subtitle и Dynamic Island expanded `.bottom`. НЕ в compact/minimal (out-of-process SpringBoard рендеринг хрупкий, см. `fix-dynamic-island.md::Шрам 3`).

Поток: `AudioSessionManager.publishMicSource()` резолвит `(kind, name)` из `currentRoute` / `wantsBluetoothMic` / `btOutputDevice`, дедупит (route change постит часто), пишет в App Group + постит `micSourceDidChange`. `RecordingActivityManager` подписан → `setMicSource()` обновляет `ContentState` **без** alertConfiguration (тихо, без banner-pop-out — смена мика не повод дёргать pop-out). `MicSourceKind`: iphone / airpods / headphones / usb / unknown, classify по `portType` + эвристика «AirPods» в имени.

Cold-launch через Action Button: `LiveActivityKickoff` (widget process) читает `lastMicSourceKind`/`Name` из App Group **до** `Activity.request()` — иначе первый pop-out frame был бы с `.unknown` пока host app не проснётся и не запушит реальное значение. Скрыто в `.idle`/`.ended` фазах (stealth — не показывать имя устройства когда ничего не пишется).

## App Group keys (источник правды)

`VoiceRecordConfig.SharedKeys` — все cross-process ключи:
- `isRecording` — Coordinator пишет, intents/widget читают.
- `pendingAction` + `pendingActionTs` — intents пишут, Coordinator подбирает на foreground.
- `wantsVoiceTab` — intents пишут при start/toggle, `TabRouter.consumeVoiceTabFlagIfSet()` потребляет.
- `forceBuiltInMic`, `autoCopyAfterStop`, `devMode`, `liveActivityTrailingPadding` — settings.
- `lastMicSourceKind` + `lastMicSourceName` — `AudioSessionManager` пишет на каждую смену route/preference, `LiveActivityKickoff` (widget process) читает до `Activity.request()`.

## Связанное

- `fact-live-activity.md` — Live Activity механика, relevanceScore, alertConfiguration policy.
- `fact-wireless-deploy.md` — deploy.sh, certificate expiry.
- `fix-dynamic-island.md` — почему Activity видна в NC но не в Island и как фиксили.
