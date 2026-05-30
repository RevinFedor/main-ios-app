# AVAudioSession — категория, lifecycle, threading

Конфигурация и lifecycle `AVAudioSession.sharedInstance()` в Voice Record. Объясняет почему именно такая категория, почему сессия живёт долго, почему все вызовы — на serial queue.

## Always-active pattern: setActive(true) один раз, не на каждую запись

`setActive(true)` дёргает `mediaserverd` через synchronous IPC, который реконфигурирует audio graph: транзит «output-only A2DP с ~10-40ms буфером» → «duplex playAndRecord с built-in mic input + A2DP output». На AirPods это включает **Bluetooth profile renegotiation** (A2DP → HFP) — ~500ms-1s **аппаратной** задержки + audible interruption в backgrounded music app. Apple QA1631 прямо: *«audio data I/O will be stopped and then restarted»*.

Поэтому activate'им сессию **один раз** в `DictationSession.start()` через `AudioSessionManager.shared.activate(...)`. Idempotency guard: если категория совпадает с текущей `session.category` И options совпадают — return early без `setCategory/setActive`. Каждая последующая запись — просто `engine.start()` + install input tap, **без** касания сессии → нет hardware flush → нет музыкальной дыры.

Privacy: orange mic indicator iOS показывает **только** когда `AVAudioEngine` реально читает samples (tap installed + engine running). Просто active `.playAndRecord` сессия без engine indicator НЕ зажигает. Это критично — иначе always-active вернул бы постоянно горящий privacy-indicator который юзер бы видел как «приложение всегда пишет».

Подтверждено WWDC lab feedback (Apple Dev Forum threads 663604, 681989).

## Category-by-target: iPhone-микрофон против AirPods-микрофона

Категория зависит от того **какой микрофон выбран**, не статична:

**iPhone built-in (default + force-iPhone лок):** `[.allowBluetoothA2DP, .mixWithOthers]`. Без `.allowBluetoothHFP`. AirPods остаются в hi-fi A2DP playback, вход падает на iPhone, **нет** BT-handshake'а ни на старте ни на свитче. Музыка не моргает.

**AirPods как мик (явный pick в picker'е):** `[.allowBluetoothHFP, .allowBluetoothA2DP]` + `.bluetoothHighQualityRecording` на iOS 26. Включение HFP обязательно — BT-микрофон **виден** в `session.availableInputs` только когда HFP в опциях (A2DP — output-only профиль, mic не несёт). Цена: AirPods переключается с A2DP на HFP → playback падает до телефонного качества 16-24kHz моно, **и любая фоновая музыка останавливается** (BT-протокол: A2DP и HFP взаимоисключающие на одном устройстве, плеер видит «звонок»).

`.bluetoothHighQualityRecording` (iOS 26, H2-чип AirPods Pro 2/4) даёт recording на 48kHz вместо HFP 16/24kHz. Не решает проблему остановки музыки — это всё ещё новый proprietary BT mode который занимает link, A2DP во время записи невозможен.

Mode зависит от пути: iPhone-путь использует `.measurement` (минимум DSP, чистый capture). AirPods-путь обязан `.default` — `.bluetoothHighQualityRecording` валидно только с `.default`.

## Visibility AirPods в picker'е через output route

На iPhone-пути (A2DP-only категория) AirPods **отсутствуют** в `session.availableInputs` потому что A2DP не несёт mic. Picker не находит их в стандартном enumeration. Чтобы пункт «AirPods Pro» был виден в меню — детектим подключённое BT-устройство через `session.currentRoute.outputs` (там AirPods всегда есть когда подключены, как A2DP output). Synthesizer-entry в picker'е: `(port: .bluetoothA2DP, name: out.portName)`. Когда юзер тапает — `selectInput()` флипает категорию на HFP-вариант, и AirPods становятся валидным input portType при реальной активации.

## Blocking API: setCategory / setActive / setPreferredInput — обязательно на serial queue

Apple SDK header для `AVAudioSession`: *«Note that activating an audio session is a synchronous (blocking) operation. Therefore, we recommend that applications not activate their session from a thread where a long blocking operation will be problematic.»* То же relevantно для `setCategory` и `setPreferredInput` — они идут через тот же synchronous IPC к mediaserverd. На Bluetooth-роуте это 1-3 секунды wait'а на handshake.

Если эти вызовы на main thread — UI замерзает, пикер выглядит сломанным (часто симптом «пункт меню исчез»). В `AudioSessionManager` всё это уехало на dedicated `audioQueue: DispatchQueue` с `qos: .userInitiated`. Public API асинхронный (`activate(completion:)`, `selectInput(_:completion:)`, `probeInputs(completion:)`) — completion на main, для UI loader'а.

Apple QA1715 дополнительно: render callback (real-time thread в Remote I/O Audio Unit) **никогда** не должен звать AVAudioSession API — они блокируют. У нас render-side только resampling, никаких session-touch'ей.

## probeInputs steals audio route — single-shot pattern

`probeInputs()` нужен потому что iOS не публикует `session.availableInputs` пока сессия не имеет категории + активации. То есть «открыли Voice tab, хотим увидеть список устройств» требует `setCategory + setActive(true)`. Эта пара перехватывает аудио-роут у backgrounded music app на ~1с (тот же hardware flush). На каждое открытие Voice tab дёргать probe — означает каждый раз обрывать музыку.

Решение: `hasProbedThisLaunch` гвард в менеджере. Probe выполняется максимум один раз за жизнь процесса. После этого `currentRoute.outputs` достаточно для UI badge'а и BT-детекции (см. секцию выше).

Реальный сценарий регрессии (без гвaрда): пикер re-probe'ил на каждый `AVAudioSession.routeChangeNotification` → probe сам генерит routeChange (reason `.categoryChange`/`.routeConfigurationChange`) → бесконечный loop, в логах стена `[Audio] [probe]` каждые ~80ms.

## Idempotency guard для setPreferredInput

`setPreferredInput()` сам по себе постит `routeChangeNotification` (reason `.categoryChange` или `.override`). Наш handler `handleRouteChange` зовёт `applyPreferredInput()` → который зовёт `setPreferredInput()` → новая нотификация → ∞ loop, main thread заблокирован, UI фризится на секунды.

Защита в `applyPreferredInput`: перед `setPreferredInput(chosen)` сравнить `session.preferredInput?.uid == chosen?.uid` → если совпадает, return. Цикл обрывается на первой итерации. То же на пикере: `onReceive(routeChange)` whitelist'ит только `.newDeviceAvailable` / `.oldDeviceUnavailable` — реальное подключение/отключение железа. Category/config-changes игнорируются (мы их сами и генерим).

## Route change mid-recording: tap rebuild с новым sampleRate

Когда юзер подключает/отключает AirPods **во время** записи, iOS переключает audio route, и **input format меняется** (built-in iPhone обычно 48kHz, AirPods HFP 16kHz, hi-q recording 48kHz). Старый input tap был installед с captured `format` от прошлого устройства, `sourceRate` зафиксирован в closure'е. Resampler `floatToS16LE16k` использует этот старый rate против нового реального — на выходе chipmunk-effect или slow-motion аудио, транскрипт garbled.

Фикс: `AudioSessionManager.onActiveRouteChange` callback. `DictationSession` подписывается, при срабатывании: `engine.stop()` → `removeTap` → `installInputTap()` (читает свежий `inputNode.outputFormat(forBus: 0)`) → `engine.prepare()` → `engine.start()`. Собранный PCM из `allFrames` сохраняется — транскрипт непрерывен за ~100ms gap во время restart'а. Без этого restart'а — `AVAudioEngineConfigurationChangeNotification` всё равно прилетит, и engine сам затихнет, но format будет stale → silent ошибка.

## Связанное

- `fact-voice-record.md` — overall Voice subsystem, killed-state Toggle.
- `fact-live-activity.md` — `.ended` pop-out перед dismiss использует тот же `setActive(false)` deactivate-в-end()-flow.
- `fix-background-intent-crashes.md` — почему deactivate обязателен на background-intent stop пути (jetsam 0x8badf00d).
