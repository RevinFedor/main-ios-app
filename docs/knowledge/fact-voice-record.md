# Voice Record subsystem

Голосовой ввод — вторая основная подсистема приложения (помимо habit-tracker'а). Soniox WebSocket стриминг с микрофона, on-device transcript history, AppIntents для Shortcuts/Action Button, Live Activity на Dynamic Island.

## Tabs: AI Chat · Voice (default) · Habits

`RootTabView` показывает три вкладки в порядке AI Chat → Voice → Habits, default selection `.voice` (не первая позиционно — `selected=.voice` ставится явно). Habit-виджет на home screen использует `widgetURL("habittracker://habits")` и `TabRouter` принимает `"habits"` (new), `"home"` (legacy), `"voice"`, `"remote"` (legacy alias → chat), `"chat"`. При tap из Control Center / Shortcut / Live Activity action — auto-switch на Voice через flag `wantsVoiceTab` в App Group.

**Почему Voice default, хотя AI Chat первый.** Voice — самая частая точка входа; Habits открывается явно через виджет или вкладку. AI Chat поставлен первым позиционно (по требованию юзера), но дефолтный выбор остаётся Voice. **AI Chat** — нативный клиент к voice-record-чату на Mac и Terminal mode к custom-terminal, см. `fact-voice-chat-tab.md`; legacy Remote/WKWebView код больше не отдельная вкладка, но его `RemoteConfig` используется Terminal mode, см. `fact-remote-tab.md`.

## Coordinator: ДВА независимых слота (параллельная запись)

```
dictationPhase:  .idle → .starting → .recording → .stopping → .idle
longPhase:       .idle → .starting → .recording → .stopping → .idle
```

`RecordingCoordinator` держит **два независимых слота** — диктовка и long — каждый со своей `@Published`-фазой (`dictationPhase` / `longPhase`), своим `DictationSession`-стоком (`dictationSession` / `longSession`), своим `startedAt` и (у диктовки) continuation. Они работают **параллельно** и больше не взаимоисключающи. Делегатные колбэки `DictationSession` маршрутизируются по identity (`session === longSession`) в нужный слот.

`isRecording` теперь = **только диктовка** (публичный computed по `dictationPhase`), `isLongRecording` = только long, `isAnythingRecording` = любой из двух. UI и Live Activity подписаны на обе фазы. `RecordingActivityManager` и `TranscriptStore` общие на оба слота.

## Параллельная запись: один общий мик → fan-out в два стока

**Железное ограничение iOS:** процессу выдаётся **один** input route в момент времени — нельзя писать long с AirPods, а диктовку с iPhone-мика одновременно. Обе записи физически идут с **одного** мика. Поэтому параллель построена не как два `AVAudioEngine` (хрупко, конфликт за железо), а как **один захват → fan-out**: `MicCaptureHub` (singleton) владеет единственным движком+тапом+ресэмплом и раздаёт готовый 16kHz PCM подписчикам-стокам. Механика хаба — `fact-audio-session.md::MicCaptureHub`.

`DictationSession` стал **стоком** (`MicPCMSink`): больше не владеет `AVAudioEngine`, получает кадры через `micDidCapture(_:)`, держит свою Soniox-сторону + сбор `.wav`. Диктовка и long — два независимых стока на одном хабе; у каждого своя копия `allFrames` → свой `.wav`. Stop одного стока **detach**'ит его от хаба, но движок продолжает крутиться пока attach'ен второй (рефкаунт в хабе — движок стопается только когда ушёл последний сток).

**Точки входа разведены:** диктовка — центральная mic-кнопка + ВСЕ intent'ы (Control Center toggle, Action Button, Shortcuts). Long — **только** кнопка `recordingtape` в приложении, без единого intent-входа. Угол-переключатель Control Center запускает/стопит диктовку параллельно идущему long, не трогая его. `isRecording` (флаг Control Center в App Group) отражает **только** диктовку. (Есть ещё флаг `isCapturing` = «любой слот пишет», синкается, но сейчас никем не читается — карточку выбора капсюля изначально им дизейблили, потом разрешили смену mid-record; флаг оставлен как потенциальный сигнал «идёт хоть какая-то запись».)

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

⚠️ **Тот же баг повторился в `ReloadSession` (retranscribe / «Return Scribble») — фикс был применён НЕ везде.** Шрам #17 пофикшен в `DictationSession`, но `ReloadSession` (отдельный one-shot путь, добавлен позже — стримит PCM сохранённого `.wav` в свежий Soniox WS) **сохранил старый `task.send(.data(Data()))`** — пустой BINARY frame. Симптом: «обычное голосовое retranscript просто бесконечно идёт и ничего не работает; для long audio так же». Корень — РОВНО #1 выше: Soniox silently игнорит binary-finalize, `{finished:true}` не приходит, `recvLoop` крутится до 300с resource-timeout (а не до видимой ошибки). Фикс: `task.send(.string(""))` + defensive 60с stall-watchdog, который cancel'ит `task` если receive завис (зеркало `stopHardCapSeconds`). **Урок:** finalize-handshake Soniox дублируется в ДВУХ местах (live `DictationSession.stop()` и `ReloadSession.run()`) — правя одно, проверь второе. Любой fix WS-протокола ищи во всех путях, что открывают Soniox-сокет (сейчас их два). `ReloadSession` бил по обоим типам записей сразу, потому что «Return Scribble» в контекст-меню показывается для ЛЮБОЙ записи с аудио (диктовка И long).

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

**Офлайн-буфер диктовки (`pending`) capнут на 10 минут.** В диктовке (`transcribe:true`) кадры, пойманные пока WS не открыт/оборвался, копятся в `pending` для повтора в Soniox при коннекте. Но **источник истины — `.wav` (`allFrames`), а `pending` лишь replay-дорожка**, поэтому она ограничена: без капа долгий офлайн растил бы массив без предела → memory-pressure jetsam убил бы **всю** запись (ровно то, чего нельзя по правилу «останавливает только Стоп»). Кап = 16kHz·60·10 сэмплов; при переполнении отбрасываются **старые** кадры (live-транскрипт потеряет начало, аудио на диске целое — перераспознаётся из истории), и на коннекте юзеру один раз показывается предупреждение про пропуск. `.wav` не трогается никогда. Переносимый принцип — `methodology/переносимый-дизайн.md::Сбой зависимости не останавливает запись`.

## Verdict-уведомление: зелёный/красный баннер на терминальной точке

**Каждая запись завершается видимым вердиктом.** `RecordingCoordinator.notice: UserNotice?` (`@Published`, `{kind: .success|.error, message, id: UUID}`) постится в терминальных точках: dictation `didStopWith`, long `didStopWith`, `reloadTranscript` done. `VoiceRecordTabView` слушает `.onChange(of: recorder.notice)` (ключ — `id`, свежий UUID каждый раз → одинаковый текст повторно показывается) и рисует top-anchored баннер (зелёный capsule + checkmark / красный + triangle), авто-дисмисс (success 2.2с, error 4с — ошибку дольше читать), тап = закрыть. Мотив: до этого успех был «тихим» (просто появлялся транскрипт), а **провал — вообще никак** (юзер не понимал, запись не удалась из-за отсутствия инета или просто пусто). Теперь провал ВСЕГДА явный.

**Матрица вердиктов (по просьбе юзера «если запись не успешна — выводить всегда ошибку»):**
- dictation: текст есть → success «Запись сохранена»; аудио есть, но текст пуст (WS оборвался) → **error** «Аудио сохранено, но текст не распознан» (partial); ни текста ни аудио → error «Запись не получилась».
- long: `.wav` сохранён → success; pcm пуст (мик не дал кадров) → error «нет аудио»; save вернул `nil` path → error «не удалось сохранить».
- reload: непустой результат → success; **пустой результат → error И НЕ перезаписываем** старый текст (иначе пустая перезапись затёрла бы хороший транскрипт — явный guard в `reloadTranscript`); throw → error с `localizedDescription`.

**Cancel НЕ постит вердикт.** Отмена (`cancel()`/`cancelLong()`) идёт через тот же `didStopWith`, что и реальный стоп, но юзер сам выбрал выбросить запись — флаги `dictationCancelled`/`longCancelled` ставятся в cancel и читаются+сбрасываются в `didStopWith`, подавляя notice. Без них отмена с частичным текстом ложно мигала бы «сохранено», а пустая отмена — ложной ошибкой. `notice` отдельный от `lastError` (тот — inline, копируемый, живёт во время записи; `notice` — glanceable вердикт только на финале).

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

`MicSourcePicker` справа от big mic button — **один** контрол (dropdown), показывает текущий активный микрофон real-time. Тап → Menu: device-строки (iPhone / AirPods) с галочкой на реально-используемом устройстве, ниже `Divider` + modifier-строка «Закрепить iPhone» (sticky `forceBuiltInMic`, галочка когда ON). Lock-pin раньше был **отдельной кнопкой-сиблингом** рядом с dropdown — перенесён ВНУТРЬ меню как toggle-строка, чтобы был один tap-target; состояние лока видно без открытия меню по маленькому оранжевому lock-badge в правом-верхнем углу карточки (+ оранжевая рамка).

**Закреп — это DEFAULT, не клетка.** Закреплённый iPhone лишь означает «по умолчанию открываемся на iPhone-мике», но строка AirPods (и любого устройства) **остаётся выбираемой**. Выбор AirPods при активном закрепе сбрасывает `forceBuiltInMic` (внутри `selectInput`: «BT pick → clear force») и переключает на AirPods; badge-замок исчезает, галочка едет на AirPods. Раньше строка была `.disabled(locked)` — это и был баг «не могу выбрать AirPods при закрепе». Детерминированность галочки (badge = реальный роут, не «BT подключён ⇒ AirPods») — `fact-audio-session.md::Picker badge`.

**Карточка выбора встроенного мика (Низ/Перед/Зад).** Справа от mic-картчки, видна **только при iPhone-мике** и когда iOS отдаёт >1 data source — Menu «Нижний (у разъёма) / Верхний (фронт) / Задний (у камеры)», галочка на **выбранном намерении** (`preferredMicDataSource`), НЕ на живом роуте (роут отражает выбор только при активном I/O — иначе галочка откатывалась бы на Низ; см. `fact-audio-session.md::Бейдж капсюля = намерение`). **Enabled и во время записи** — менять капсюль можно mid-record (тот же порт/частота, `MicCaptureHub` ловит config-change и пересобирает tap). Зеркальный пикер в long-панели синхронен через `micDataSourceDidChange` — один общий капсюль на ВСЕ записи (одна сессия = один роут). Раньше тут была карточка выбора динамика (speaker/receiver) — удалена как бесполезная для рекордера. Механика и graveyard про polar patterns/output — `fact-audio-session.md::Выбор встроенного мика`.

`AudioSessionManager.probeInputs()` вызывается в `.onAppear` — без активной session iOS не публикует AirPods в `availableInputs`, picker показывал бы только built-in.

## Provisioning expiry counter

`ProvisioningInfo.swift` парсит `Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")`, slice'ит embedded plist между `<?xml` и `</plist>` маркерами (CMS-wrapper нельзя через `String(data:encoding:)` из-за binary bytes), извлекает `ExpirationDate`. `ProvisioningExpiryView` показывает days remaining (зелёный/оранжевый/красный по близости истечения) в обоих Settings sheets (Voice + Habit).

**Почему не сохраняем install date.** Free-Apple-ID profile живёт ~7 дней с момента выпуска через `xcodebuild -allowProvisioningUpdates`, не с момента install. Provisioning ExpirationDate — источник правды.

## Log counter рядом с copy-button

В dev-mode navbar показывает `<copy-icon> <N>` где N = количество строк в текущем `VRLog` файле. Обновляется через `Timer.publish(every: 1)` пока view on screen, при `clear` снимается в 0, при `copy` пересчитывается.

`VRLog.lineCount()` считает raw `\n` байты (`reduce + count of 0x0A`) — дешевле чем split, и достаточно для индикатора «лог рос с последней очистки».

## История: карточка, табы, статус-заметка, объединение

Экран истории (`TranscriptHistoryView`) — список `TranscriptEntry`, по умолчанию newest-first, на `List` с нативными `.swipeActions` (есть отдельный режим перестановки на кастомном drag-списке — см. ниже). Карточка (`EntryRow`) и модель прошли несколько раундов редизайна; ниже только невидимый контекст.

**Заметка — явный статус `noteFlag`, не производное от заголовка.** В модели `noteFlag: Bool?` отдельно от `title`. Раньше «заметка» выводилась из факта «есть кастомный title» — теперь это два независимых признака. Computed `isNote = (noteFlag == true) || hasCustomTitle` — обратная совместимость: записи со старым кастомным заголовком всё ещё читаются как заметки, но новый флаг позволяет пометить запись заметкой **без** переименования (и наоборот). Зачем разделили: кнопка «+Notes» даёт статус, не трогая авто-заголовок. `noteFlag` Optional + nil-default — Codable-миграция старого JSON без ключа. При merge результат = заметка если **любая** сторона была заметкой (`target.isNote || source.isNote`). Принцип — `methodology/переносимый-дизайн.md::Направленное слияние` соседствует с этим, но «статус явным полем» — само по себе модельное решение.

**Четыре таба сверху: `All / Voices / Notes / Long`, дефолт — `Voices`.** Segmented в navbar `.principal`. `Voices` = расшифрованные записи, которые НЕ заметки И НЕ long-аудио (`!isNote && !isLong`), `Notes` = только заметки (`isNote`), `Long` = только long-аудио (`isLong`), `All` = всё. То есть как только запись помечена заметкой (+Notes или кастомный заголовок) — она уходит из Voices в Notes; long-аудио всегда в своём ведре Long и никогда не показывается в Voices/Notes. Дефолт — Voices, потому что сырые расшифровки это основной поток. Таб `Notes` несёт счётчик `Notes (N)` — число заметок; скобки показываются только при N>0.

**Long — отдельный тип записи (`RecordKind.longAudio`), не подвид заметки.** В модели `recordKind: RecordKind?` (`dictation` | `longAudio`) — Optional + nil-default, старый JSON декодится как `dictation` (тот же приём миграции, что `noteFlag`). `kind = recordKind ?? .dictation`, `isLong = kind == .longAudio`. **`isNote` для long всегда `false`** (short-circuit первой строкой `if isLong { return false }`): у long-записи авто-заголовок `запись_NNN`, который без этого читался бы как кастомный title и утёк бы в Notes. `recordKind` протянут через ВСЕ конструкторы (`updateText`/`updateTitle`/`setNoteFlag`/`updateTimestamp`; `mergeDirectional` берёт `target.recordKind`) — иначе любая правка/merge сбрасывала бы тип в dictation. Бейдж на title-chip в истории: long → красный `recordingtape`, заметка → жёлтый `note.text` (long имеет приоритет, запись не бывает обоими).

**Режим перестановки: ручной порядок через `sortIndex`, приоритетнее даты.** Зачем вообще: свайп-merge склеивает только **соседа**, а юзеру нужно было склеить «через одну» — для этого надо сперва переставить карточки рядом. В модели — `sortIndex: Int?` (Optional+nil, миграция как `noteFlag`/`recordKind`). **Два регламента сортировки** в `TranscriptStore.sortEntries` (единственная точка, через неё идут `loadAll` и все мутации): пока НИ у одной записи нет `sortIndex` (состояние любой инсталляции до первой перестановки и всего старого JSON) — чистый timestamp-desc, байт-в-байт прежнее поведение; как только хоть у одной появился — **ручной порядок побеждает дату** (`sortIndex` asc, timestamp лишь tie-break). `append` в ручном регламенте даёт новой записи `(min существующий − 1)`, чтобы она всё равно вставала сверху; `sortIndex` протянут через ВСЕ конструкторы (иначе правка/merge сбросила бы порядок), merge берёт `target.sortIndex` (цель держит позицию), date-editor больше **не** двигает позицию в ручном регламенте (порядок приоритетнее). `Coordinator.reorderHistory(orderedVisibleIds:)` → `store.reorder` перенумеровывает ВСЮ историю плотно: видимые (отфильтрованные табом) строки берут новый порядок, скрытые остаются пришпилены к своим видимым соседям (иначе смена таба путала бы их).

**Drag по всей карточке — порт механизма Habits, НЕ нативный `List`.** Нативный `List.onMove` тащит только за ручку — сделать саму карточку хваталкой через `List` нельзя, поэтому в режиме История переключается с `List` на кастомный `ScrollView`+`LazyVStack` с общим `ReorderLongPressGesture` (тот же UIKit-long-press, что у Habits, `shouldRecognizeSimultaneouslyWith→true` для pan: быстрый свайп скроллит, удержание хватает). Полная механика жеста и graveyard pure-SwiftUI попыток — `fact-habit-tracker.md::Перестановка`, тут только **отличия Истории**: (1) карточки **переменной высоты** (у Habits фиксированные 52pt), поэтому make-room и hit-test считаются по **измеренным** высотам/центрам, а резалтинг-центры **замораживаются** в момент захвата (`frozenMidYs`) — иначе съезжающие соседи кормили бы расчёт цели в петлю; (2) карточка в режиме инертна (`EntryRow(interactive:false)` — `.allowsHitTesting(false)` + контекст-меню снимается через `ConditionalContextMenu`, иначе его long-press дрался бы с reorder-long-press); (3) тогл — **FAB справа-снизу** (⇅→✓, перенесён из тулбара по просьбе юзера, как у Habits); ручка-«≡» оставлена декоративной для теста, хват — по всей карточке.

**Драг вниз закрывал sheet — `interactiveDismissDisabled` в режиме.** Симптом: *«перетаскиваю карточку вниз, а вниз опускается само меню Истории»*. История — это **sheet**, у него встроенный pull-to-dismiss, а наш `ReorderLongPressGesture` распознаётся **одновременно** с другими жестами (это и даёт «быстрый свайп всё ещё скроллит») → драг карточки вниз заодно кормил dismiss-pan sheet'а. У Habits этого нет — там полноценная вкладка, не sheet. Фикс: `.interactiveDismissDisabled(isReordering)` — свайп-закрытие глушится только в режиме; Done и FAB-✓ (программные, не свайп) закрывают по-прежнему.

**Long-запись: тот же mic→`.wav` pipeline, но БЕЗ Soniox.** Кнопка слева от микрофона (`recordingtape`) — `Coordinator.toggleLong()` → `startLong()`. Под капотом `DictationSession(transcribe: false)`: микрофон пишется в `allFrames` (→ `.wav`) ровно как при диктовке, но `connectSoniox()` не вызывается, а вместо него сразу шлётся `dictationDidConnect` (UI выходит из `.starting` в `.recording` без вечного спиннера). Захваченные фреймы НЕ кладутся в `pending` (WS его не дренирует — иначе на длинной записи буфер растёт безгранично; `guard transcribe else { return }` в `micDidCapture`). `stop()` для long попадает в ветку «WS не открыт» → немедленный `fireStopped()` без 60-секундного finalize-watchdog'а. Сохранение в `didStopWith` — ветка по identity `session === longSession`: `append(text:"", kind:.longAudio, title: запись_NNN)`, без autocopy и без `lastEntryId` (это диктовочные понятия). **Диктовка и long идут параллельно** (два стока на общем `MicCaptureHub`), НЕ взаимоисключающи — см. «Параллельная запись» выше.

**Long пишется на диск В РЕАЛЬНОМ ВРЕМЕНИ, а не копится в памяти до Stop (`LongAudioFileWriter`).** Симптом до фикса: *«при long-записи я закрыл приложение и оно пропало»* — звук жил только в `allFrames` (RAM), на диск попадал лишь в момент Stop, и убийство процесса (свайп вверх, jetsam под память, краш) стирал всё. Теперь `startLong` открывает `LongAudioFileWriter`: `.wav` создаётся СРАЗУ с placeholder-заголовком (нулевые размеры), и каждый кадр из `micDidCapture` стримится в файл через `FileHandle`. Два неочевидных решения: **(1)** запись идёт на **отдельной serial-очереди** (`qos:.utility`), а не в аудио-колбэке — колбэк хаба нельзя блокировать на дисковом I/O (тот же класс «не блокируй realtime-поток», что и `setActive` не на main, см. `fact-audio-session.md::Blocking API`). **(2)** в writer-режиме кадры в `allFrames` **НЕ копятся** (`micDidCapture`: `if let writer { writer.append(pcm); return }`) — иначе многочасовая запись растила бы RAM без предела; единственный источник правды — файл. На Stop `writer.finish()` патчит два размерных поля заголовка (RIFF chunkSize по offset 4, data-subchunk по offset 40) из реального размера файла — байты аудио не переписываются. `discard()` (на cancel) закрывает и удаляет недописанный файл. Нагрузка ничтожна: 16kHz/mono/s16le = ~32 КБ/с на флеш. Заголовок-строитель вынесен в `TranscriptStore.wavHeaderBytes` (static) — стрим, recovery и `saveWav` дают **байт-идентичный** заголовок.

**Восстановление осиротевшей long-записи на cold-launch (`recoverOrphanedLong`).** Поскольку файл уже на диске, остаётся вернуть его после убийства. В момент `startLong` в App Group пишется маркер `{longInProgressPath, longInProgressTitle, longInProgressStart}`; на чистом Stop/cancel он **чистится** (`clearLongInProgressMarker`). Если маркер **пережил** в следующий cold-launch — значит был kill без Stop. `RecordingCoordinator.init` (до старта любой новой записи) вызывает `recoverOrphanedLong`: чинит заголовок недописанного `.wav` через `finalizeStreamedWav(atPath:)` (тот же патч size-полей из размера файла — идемпотентен) и `append`'ит запись в Long. Три тонкости: **(1)** `append` получил параметр `timestamp:` (дефолт `Date()`) — recovery передаёт **исходное** время старта из маркера, чтобы запись встала в историю там, где реально началась, а не на момент перезапуска. **(2)** маркер чистится **ПЕРВЫМ делом** в `recoverOrphanedLong`, ещё до попытки восстановления — иначе сбой восстановления зациклил бы попытку на каждом запуске. **(3)** «время остановки» для плашки = **mtime файла** (`.modificationDate`) — последний кадр, успевший лечь на диск до kill; точнее у нас нет.

*Graveyard — уведомление в момент закрытия отвергнуто.* Юзер хотел *«уведомление если приложение исполня закрываю… запись остановлена»*. На iOS это **невозможно надёжно**: при свайп-убийстве в переключателе система НЕ даёт процессу исполнить код «меня закрывают» (нет гарантированного хука уровня `applicationWillTerminate` для user-swipe-kill). Поэтому сигнал-в-момент-события заменён на **сверку-при-возврате**: ничего не шлём на закрытие, а на следующем открытии показываем плашку восстановления. Не переизобретать notify-on-close.

**Плашка восстановления под кнопкой «Open History» (`recoveredLongPlate`).** Когда `recoverOrphanedLong` что-то вернул, публикуется `recoveredLong: RecoveredLongInfo?`, и в пустом состоянии Voice-экрана под «Open History» появляется оранжевая (не красная — ничего не сломалось, запись СОХРАНЕНА) плашка: «`запись_007` остановлена в 15:52 · 4:32 / приложение закрыто без остановки записи». Тап = открыть Историю. Гаснет (`dismissRecoveredLong`) при открытии Истории **любым путём** — через `.onChange(of: showHistory)`, повешенный на показ sheet'а: покрывает и тулбар-кнопку, и «Open History», и тап по самой плашке одним обработчиком (юзер: *«если я открыл историю, то плашка пропадает»*). Принцип — `methodology/переносимый-дизайн.md::Долговечная запись + сверка-при-возврате`. User-flow целиком — `methodology/сценарии-использования.md::long-запись пережила убийство`.

**Long самодостаточен внутри своей иконки, но больше НЕ блокирует диктовку (separation of concerns + параллель).** Юзер явно: «вся long-запись именно внутри этой иконки, её состояние; элементы максимально независимы». Long не протекает в общие UI-каналы диктовки, НО при этом не мешает диктовке идти параллельно:
- **`bigRecordButton` (центральная mic) во время long ПОЛНОСТЬЮ рабочая** — тап стартует/стопит диктовку параллельно идущему long (раньше был `guard !long` no-op «на будущее — параллельные записи»; это будущее наступило, guard снят). «Recording»-вид (red+stop) гейтится `isRecording` (теперь = только диктовка).
- **Нижний ряд кнопок.** Левый слот: при активной диктовке = ✕ Cancel (`dictationPhase != .idle`), иначе = `longRecordButton` (recordingtape, старт-only; стоп long живёт в панели, не тут). При параллели (long идёт + стартовала диктовка) левый слот показывает Cancel диктовки — long уже виден своей панелью сверху.
- **Стоп/отмена long живут ТОЛЬКО в панели** (`stopLong()` / `cancelLong()`), не в нижнем ряду и не в Live Activity.
- **`toolbarTitle` следует `dictationPhase`** — навбар показывает «Recording…»/«Finalizing…» для диктовки; long его не трогает.
- **Footer-таб Voice: бейдж «REC» и `mic.fill` гейтятся `isRecording`** (= только диктовка, `HabitTrackerApp.RootTabView`). Long не зажигает вкладку.
- **Карточка выбора встроенного мика — enabled всегда** (и в idle, и mid-record): смена капсюля Низ/Перед/Зад безопасна на лету (один порт/частота, `MicCaptureHub` пересобирает tap на config-change). Раньше дизейблили по `isCapturing` — отменено.

**Раскрытие панели — slide из-под иконки.** Reveal-блок в `ZStack(alignment: .top)` с `.padding(.top, 18)` (зазор от иконки) и `.clipped()`, `.transition(.move(edge: .top))` — детали выкатываются ВНИЗ начиная чуть ниже иконки, а не из самого верха экрана (без clip контент появлялся бы от y=0).

**Счётчик `запись_NNN` — монотонный, в App Group.** `VoiceRecordConfig.SharedKeys.longRecordingCounter`, инкремент в `reserveNextLongTitle()` на старте. Идентификатор, а не live-счётчик: лезет вверх даже после удаления записей, чтобы две выжившие никогда не делили номер. Формат `String(format: "%@_%03d", "запись", n)` → `запись_001`, `запись_007`.

**Панель long (`longRecordingPanel`) — раскрывающаяся, по умолчанию свёрнута до ОДНОЙ иконки.** Юзер: «по центру только этот компонент, только иконка; всё остальное — когда кликну; иконки выпадающего списка тоже не надо». Свёрнутое состояние = только белый `recordingtape`. Жест **асимметричный**: раскрытие — **долгое нажатие** (`.onLongPressGesture`, юзер: «раскрытие по клику не должно работать, только по зажатию»), сворачивание — обычный **tap** (`.onTapGesture` с `guard longPanelExpanded` — в свёрнутом виде тап ничего не делает, чтобы случайно не открыть; принцип — `methodology/переносимый-дизайн.md::Жест под вес действия`). Раскрытое: заголовок `запись_NNN`, **самотикающий таймер** `Text(timerInterval: longStartedAt ... .distantFuture)` (system тикает бесплатно, без `@State`; драйвит от собственного `longStartedAt` слота, независимо от параллельного диктовочного таймера), и две круглые кнопки — ✕ Cancel (`recorder.cancelLong()`, жёсткий сброс long-слота) и ■ Stop (`recorder.stopLong()`, сохраняет `.wav`). Обе целят **только** long-сток, не трогают параллельную диктовку. Кнопки прячутся в `.stopping` long-слота (`isLongStopping`, показывается «Сохранение…»). Ниже кнопок — **зеркальный `MicSourcePicker`** (тот же контрол, что в нижнем ряду): юзер просил выбор мика «в обоих местах»; оба инстанса драйвят один общий route (мик один на обе записи), поэтому всегда согласованы. `longPanelExpanded` сбрасывается в `false` через `.onChange(of: isLongRecording)` когда long не активна. Таймер сознательно ЗДЕСЬ, не в Live Activity. Панель рендерится **независимо** в `transcriptArea` (`if recorder.isLongRecording`) — может сосуществовать с диктовочным транскриптом ниже (параллель). Вибрация раскрытия — отдельный шрам, см. `fix-ios-stability.md::Haptic на свежем генераторе`.

**Кнопка «+Notes» на главном Voice-экране и в истории.** На главном экране (`VoiceRecordTabView`) она стоит между Copy и Share и переводит **последнюю** запись (`Coordinator.lastEntryId`, ставится при append в `didStopWith`, сбрасывается в `start()`) в статус заметки. В истории тот же action доступен из long-press меню конкретной карточки (`toggleEntryNote(id:)`) — это нужно, чтобы старую голосовую заметку можно было добавить в Notes без возврата к главному экрану. Тогл: помечена → жёлтая «In Notes» с галочкой, повторный тап снимает (`setNoteFlag`). Заголовок при этом не трогается — остаётся auto-derived. Long-записи не промоутятся в Notes: для них `isNote` всегда false и они живут в отдельном Long bucket.

**Объединение направленное (`TranscriptStore.mergeDirectional`), НЕ хронологическое.** Прошлая версия склеивала по времени с midpoint-датой и новым id — переделано. Теперь: запись, на стрелку которой нажали — **source (вторичная)**, она дописывается в **конец** соседа; сосед по направлению — **target**, держит свою идентичность (id, title, date, позицию в списке). Текст: `target.text + seam-marker + source.text` (target первым; склейка — через маркер шва, не `\n`, см. ниже). Аудио: PCM target первым, потом source, в новый `.wav` (срезая 44-байтные заголовки); одиночный путь переиспользуется (guard от удаления). `mergeCount` — сумма (`[N]`-бейдж). Сосед резолвится из **видимого** (отфильтрованного табом) списка, не из полного `history` — под Voices заметки скрыты, и «карточка выше» на экране ≠ index−1 в `recorder.history`; поэтому View передаёт явный `targetId`, а `Coordinator.mergeEntry(sourceId:targetId:)` не пересчитывает соседа сам. Мотивация направленности — юзер выбрал явно: *«приоритет у той заметки, в которую идёт мердж; та, на которой нажал стрелку — вторична»*.

**Merge-анимация и стартовый лаг — см. `fix-ios-stability.md::SwiftUI List`.** Two-phase (короткий render-leave → коммит данных → нативное removal List сдвигает соседей) и вынос тяжёлого `.wav`-concat в `Task.detached` (иначе синхронный I/O морозил первый кадр на 0.5-1с) задокументированы там как платформенная механика.

**Шов склейки — невидимый маркер `\u{1D}` (ASCII Group Separator) в `entry.text`, НЕ `\n`.** Юзер хотел видеть «в месте склеивания разделитель», но при копировании — обычную пустую строку. Решение: `mergeDirectional` склеивает стороны через `TranscriptEntry.mergeMarker` (`"\u{001D}"`) вместо `\n`. Это control-char для разделения записей — никогда не встретится в расшифровке Soniox и чисто round-trip'ится через JSON. Маркер **никогда не показывается дословно**, три производных в модели:
- `plainText` — маркер → одна пустая строка (`\n\n`). Это user-facing текст: **копирование** (`copyPayload`), `displayTitle`, **счётчик символов** и **gate Show-more** (иначе control-char раздул бы count), **collapsed-превью** и контекст-меню preview. Для несклеенной записи `plainText == text` **дословно** (guard `contains` до любого trim — старые записи байт-в-байт не трогаются).
- `textSegments` — `text.components(separatedBy: marker)`, каждый сегмент trim'ается, пустые отбрасываются. По одному элементу на свёрнутую запись.
- `hasMergeSeams` — есть ли хоть один шов.

Рендер: **только** в expanded-карточке И `hasMergeSeams` → `VStack` сегментов с `MergeSeam`-разделителем между ними (hairline + центральный глиф `arrow.triangle.merge`). Во всех остальных ветках (collapsed, несклеенная запись) — один `Text(plainText)`. Обратная совместимость полная: записи, склеенные ДО этого, не имеют маркера → `hasMergeSeams == false`, рендерятся как раньше. **Инвариант:** любой новый потребитель текста записи должен брать `plainText`/`displayTitle`, не сырой `.text` — иначе control-char утечёт в UI/буфер. `deriveTitle` дополнительно сам стрипает маркер (defensive — title-editor placeholder передаёт сырой `text`).

**Контекст-меню карточки (long-press): Play · Copy Text · Notes/In Notes · Поделиться аудио · Return Scribble · Delete.** «Notes» — тот же noteFlag-тогл, что на главном Voice-экране, но целится в конкретную запись; для long-записей скрыт, потому что Long — отдельный bucket, не заметка. «Поделиться аудио» — `ShareLink(item: URL(fileURLWithPath: entry.audioPath))` (экспорт самого `.wav`-файла, не строки), показывается для ЛЮБОЙ записи с аудио (диктовка ИЛИ long) — отправить звук на Mac/куда угодно через системный share-sheet. «Copy Text» скрыт когда `text.isEmpty` (long-записи без расшифровки → у них в меню Copy Text нет, но есть Play / Поделиться аудио / Return Scribble / Delete).

**Свайп влево — нативный `.swipeActions`, icon-only.** Три кнопки горизонтально: Delete (у края, full-swipe удаляет), merge ↓, merge ↑. `.labelStyle(.iconOnly)` обязателен: на iOS 26 swipe-кнопка по умолчанию рисует **icon + title** (на iOS ≤18 — только icon), без явного стиля появлялись подписи. Полный цикл «кастомный свайп с круглыми вертикальными кнопками на ScrollView+LazyVStack» был прототипирован и откатан — почему остались на нативном, см. `fix-ios-stability.md` (iOS-26 баг скролла) и `methodology/переносимый-дизайн.md::Нативный компонент vs кастом`.

**Копирование — фиксированный формат, 4 строки.** Copy (кнопка-пилюля в шапке карточки + пункт контекст-меню) кладёт в буфер: строка 1 `date: YYYY-MM-DD HH:MM:SS`, строка 2 пустая, строка 3 заголовок (`displayTitle`), строка 4 текст. Формат точный по просьбе юзера (не locale-formatted). Иконка копи-кнопки в **фиксированном боксе** 16×16 — `doc.on.doc`↔`checkmark` имеют разный интринсик-размер, и без фиксации своп глифа менял высоту пилюли → строка List переизмерялась и прыгала вверх-вниз.

**Постоянное скругление карточки.** `RoundedRectangle(14)` фон + `clipShape` всегда, и `contextMenu { } preview:` той же формы. Иначе скруглённые углы появлялись только в момент long-press preview (iOS приподнимает строку со скруглением), и карточка визуально скакала из прямых углов в скруглённые. Принцип — `methodology/переносимый-дизайн.md::Постоянный affordance`.

**Редактируемый заголовок (`title: String?`).** Опционален: `nil` = деривить из текста (первые слова до ~28 символов, обрезка по границе слова + «…»). При reload/смене даты сохраняется; при merge берётся `target.title`. Иконка `note.text` на chip'е — при `isNote` (кастомный title ИЛИ +Notes-флаг). Заголовок-chip слева, дата-chip справа — кликабельные пилюли (`Capsule` 0.08), тап открывает `TitleEditorSheet` / `DateEditorSheet` (графический `DatePicker`). Карандаш-affordance убран — chip-стиль сам сигналит редактируемость.

**Свёртка превью без анимации (3 строки).** Collapsed `lineLimit = 3`, тап разворачивает. `expanded.toggle()` **без** `withAnimation`: анимация смены lineLimit заставляла `List` пересчитывать высоту строки на лету и дёргать scroll-offset.

**Footer карточки истории: `[Show more] [символы] │ [m:ss]` слева, дата-chip справа.** Число символов (`entry.plainText.count` — flatten'утый, чтобы маркер шва не раздувал count) **спарено** с «Show more» — оба под одним gate'ом `plainText.count > 110`. Поэтому короткая заметка и long-аудио (у которого `text` пуст и Show more нет) показывают в левом-нижнем углу **только длительность**. Тонкий divider `│` появляется лишь когда символы слева от длительности есть.

**Длительность аудио считается из РАЗМЕРА `.wav`, а не через `AVAudioFile`.** Все наши файлы — фиксированный формат 16kHz/s16le/mono (`TranscriptStore.wavHeader`), поэтому `seconds = (fileSize − 44) / (16000·2)` точна без открытия файла. Грузится в `.task(id: entry.audioPath)` через `Task.detached(.utility)` — `attributesOfItem` это I/O, на render-path его держать нельзя (то же правило, что в `fix-ios-stability.md::main-thread I/O`). Ключ — `audioPath`, не `id`: merge переписывает `.wav` в новый путь, и `.task` должна перечитать длину. `< 0.5с → nil` (нечего показывать). **Связка-инвариант:** если когда-нибудь формат `.wav` перестанет быть 16k/mono/s16le, эта формула молча соврёт — длительность завязана на `wavHeader`, держать их синхронно.

**Скорость воспроизведения в плеере истории (`AudioPlayerController.rate`).** Кнопка слева от ✕ в `PlayerBar` — одиночный тап циклит `1 → 1.5 → 2 → 2.5 → (wrap на 1)` (`VoiceRecordConfig.playbackRates`, без 3×). Дефолт нового воспроизведения — в Settings (`playbackDefaultRate` в App Group, fallback 1.0), читается заново на каждом старте → смена в Settings подхватывается со следующей записи без рестарта. **Гочи `AVAudioPlayer.rate`:** (1) `enableRate = true` обязателен ДО `play()`, иначе `rate` молча игнорируется; (2) `play()` СБРАСЫВАЕТ `rate` на 1.0 — поэтому переустанавливаем `p.rate` ПОСЛЕ каждого `play()` (и в старте, и в resume из паузы), иначе после паузы скорость слетает на 1×. Лейбл (`VoiceRecordConfig.playbackRateLabel`) срезает `.0` → `1×`/`1.5×`/`2×`/`2.5×`; helper в Config, потому что используется и пилюлей-кнопкой, и сегментед-пикером Settings.

## Mic source в Live Activity

Live Activity показывает какой вход сейчас пишется — в Lock Screen / Notification Center subtitle и Dynamic Island expanded `.bottom`. НЕ в compact/minimal (out-of-process SpringBoard рендеринг хрупкий, см. `fix-dynamic-island.md::Шрам 3`).

Поток: `AudioSessionManager.publishMicSource()` резолвит `(kind, name)` из `currentRoute` / `wantsBluetoothMic` / `btOutputDevice`, дедупит (route change постит часто), пишет в App Group + постит `micSourceDidChange`. `RecordingActivityManager` подписан → `setMicSource()` обновляет `ContentState` **без** alertConfiguration (тихо, без banner-pop-out — смена мика не повод дёргать pop-out). `MicSourceKind`: iphone / airpods / headphones / usb / unknown, classify по `portType` + эвристика «AirPods» в имени.

Cold-launch через Action Button: `LiveActivityKickoff` (widget process) читает `lastMicSourceKind`/`Name` из App Group **до** `Activity.request()` — иначе первый pop-out frame был бы с `.unknown` пока host app не проснётся и не запушит реальное значение. Скрыто в `.idle`/`.ended` фазах (stealth — не показывать имя устройства когда ничего не пишется).

## App Group keys (источник правды)

`VoiceRecordConfig.SharedKeys` — все cross-process ключи:
- `isRecording` — **только диктовочный слот**. Coordinator пишет, Control Center `ControlValueProvider` + Shortcut toggle читают (фоновый long НЕ должен зажигать красный toggle).
- `isCapturing` — **любой слот пишет мик** (диктовка ИЛИ long). Синкается, но сейчас НИКЕМ не читается: изначально гейтил дизейбл карточки капсюля, потом смену mid-record разрешили (`MicCaptureHub` пересобирает tap на config-change). Оставлен как потенциальный «идёт хоть какая-то запись» сигнал.
- `pendingAction` + `pendingActionTs` — intents пишут, Coordinator подбирает на foreground.
- `wantsVoiceTab` — intents пишут при start/toggle, `TabRouter.consumeVoiceTabFlagIfSet()` потребляет.
- `forceBuiltInMic`, `autoCopyAfterStop`, `devMode`, `liveActivityTrailingPadding` — settings.
- `lastMicSourceKind` + `lastMicSourceName` — `AudioSessionManager` пишет на каждую смену route/preference, `LiveActivityKickoff` (widget process) читает до `Activity.request()`.

## Связанное

- `fact-live-activity.md` — Live Activity механика, relevanceScore, alertConfiguration policy.
- `fact-wireless-deploy.md` — deploy.sh, certificate expiry.
- `fix-dynamic-island.md` — почему Activity видна в NC но не в Island и как фиксили.
