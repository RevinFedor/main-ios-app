# AVAudioSession — категория, lifecycle, threading

Конфигурация и lifecycle `AVAudioSession.sharedInstance()` в Voice Record. Объясняет почему именно такая категория, почему сессия живёт долго, почему все вызовы — на serial queue.

## Always-active pattern: setActive(true) один раз, не на каждую запись

`setActive(true)` дёргает `mediaserverd` через synchronous IPC, который реконфигурирует audio graph: транзит «output-only A2DP с ~10-40ms буфером» → «duplex playAndRecord с built-in mic input + A2DP output». На AirPods это включает **Bluetooth profile renegotiation** (A2DP → HFP) — ~500ms-1s **аппаратной** задержки + audible interruption в backgrounded music app. Apple QA1631 прямо: *«audio data I/O will be stopped and then restarted»*.

Поэтому activate'им сессию **один раз** в `DictationSession.start()` через `AudioSessionManager.shared.activate(...)`. Idempotency guard: если категория совпадает с текущей `session.category` И options совпадают — return early без `setCategory/setActive`. Каждая последующая запись — просто `engine.start()` + install input tap, **без** касания сессии → нет hardware flush → нет музыкальной дыры.

Privacy: orange mic indicator iOS показывает **только** когда `AVAudioEngine` реально читает samples (tap installed + engine running). Просто active `.playAndRecord` сессия без engine indicator НЕ зажигает. Это критично — иначе always-active вернул бы постоянно горящий privacy-indicator который юзер бы видел как «приложение всегда пишет».

Подтверждено WWDC lab feedback (Apple Dev Forum threads 663604, 681989).

## MicCaptureHub: один захват → fan-out в N стоков (параллельная запись)

**Зачем.** Диктовка и long-запись идут параллельно (см. `fact-voice-record.md::Параллельная запись`), но iOS отдаёт процессу **один** input route — два `AVAudioEngine` на одном железе хрупки и конфликтуют. Поэтому захват вынесен в singleton `MicCaptureHub`: **один** `AVAudioEngine` + один tap + ресэмпл в 16kHz, раздача готового PCM подписчикам (`MicPCMSink`).

**Рефкаунт движка.** `attach(sink)` стартует сессию (через `AudioSessionManager.activate`) + движок на **первом** стоке; `detach(sink)` стопит движок только когда ушёл **последний**. Сток, нажавший stop, делает `detach` — движок продолжает крутиться для второго стока. `AVAudioSession` при этом НЕ деактивируется (always-active паттерн остаётся; деактивация — только intent-stop когда второй слот idle, см. ниже).

**Fan-out.** Tap-callback ресэмплит native-rate Float32 → 16kHz s16le **один раз** и пушит одну и ту же `Data` каждому стоку через `micDidCapture(_:)`. Каждый сток держит свою копию в `allFrames` → свой `.wav`. Стоки слабо-держатся (`weak`) — хаб не продлевает их жизнь (владелец — Coordinator).

**Route-change rebuild живёт В ХАБЕ.** Когда юзер втыкает/вынимает AirPods mid-record, `AudioSessionManager.onActiveRouteChange` теперь подписан **хабом**: он гасит движок, переустанавливает tap (читает свежий `inputNode.outputFormat` нового устройства), рестартит. Стоки получают только чистый 16kHz и **не знают** про смену rate — весь класс багов «chipmunk при смене устройства» заперт внутри хаба. Раньше rebuild был в `DictationSession.rebuildInputTap`; при двух стоках это породило бы два конфликтующих rebuild'а на один движок, поэтому он строго в одном месте.

**Ресэмплинг (`floatToS16LE16k`) переехал из `DictationSession` в хаб** — `nonisolated`, на render-thread, никаких AVAudioSession-вызовов (QA1715).

## Category-by-target: iPhone-микрофон против AirPods-микрофона

Категория зависит от того **какой микрофон выбран**, не статична:

**iPhone built-in (default + force-iPhone лок):** `[.allowBluetoothA2DP, .mixWithOthers]`. Без `.allowBluetoothHFP`. AirPods остаются в hi-fi A2DP playback, вход падает на iPhone, **нет** BT-handshake'а ни на старте ни на свитче. Музыка не моргает.

**AirPods как мик (явный pick в picker'е):** `[.allowBluetoothHFP, .allowBluetoothA2DP]` + `.bluetoothHighQualityRecording` на iOS 26. Включение HFP обязательно — BT-микрофон **виден** в `session.availableInputs` только когда HFP в опциях (A2DP — output-only профиль, mic не несёт). Цена: AirPods переключается с A2DP на HFP → playback падает до телефонного качества 16-24kHz моно, **и любая фоновая музыка останавливается** (BT-протокол: A2DP и HFP взаимоисключающие на одном устройстве, плеер видит «звонок»).

`.bluetoothHighQualityRecording` (iOS 26, H2-чип AirPods Pro 2/4) даёт recording на 48kHz вместо HFP 16/24kHz. Не решает проблему остановки музыки — это всё ещё новый proprietary BT mode который занимает link, A2DP во время записи невозможен.

Mode зависит от пути: iPhone-путь использует `.measurement` (минимум DSP, чистый capture). AirPods-путь обязан `.default` — `.bluetoothHighQualityRecording` валидно только с `.default`.

## Visibility AirPods в picker'е через output route

На iPhone-пути (A2DP-only категория) AirPods **отсутствуют** в `session.availableInputs` потому что A2DP не несёт mic. Picker не находит их в стандартном enumeration. Чтобы пункт «AirPods Pro» был виден в меню — детектим подключённое BT-устройство через `session.currentRoute.outputs` (там AirPods всегда есть когда подключены, как A2DP output). Synthesizer-entry в picker'е: `(port: .bluetoothA2DP, name: out.portName)`. Когда юзер тапает — `selectInput()` флипает категорию на HFP-вариант, и AirPods становятся валидным input portType при реальной активации.

## Picker badge = `currentRoute.inputs`, НЕ «BT подключён ⇒ AirPods» (display-vs-reality)

**Canonical source of truth для отображаемого микрофона — `session.currentRoute.inputs.first`, и только он.** Apple docs прямо: *«To see the actual current input port, use the currentRoute property»*; `preferredInput` — это **hint**, не гарантия (после route/category change iOS обнуляет его в nil), а `availableInputs` category-aware и на A2DP-only пути вообще не содержит BT-микрофон. `currentRoute.inputs` «never misleads — always reflects hardware state».

**Шрам.** Picker считал `effective = (btDevice != nil) ? .airPods : .iPhone` — то есть «AirPods подключены к выводу (музыка) ⇒ значит они и микрофон». На дефолтном A2DP-only пути это **ложь**: BT не несёт mic, запись идёт со встроенного айфоновского, но галочка стояла на AirPods. Симптом юзера: «не могу выбрать AirPods» — UI показывал их уже выбранными, а реально писал iPhone; при этом сам `AudioSessionManager.publishMicSource` логировал правильный `kind=iphone` (расхождение видно в логах как `publishMicSource → iphone` рядом с `[Picker] effective=airPods`).

**Правило.** `currentMicSource()` читает **живой input-порт ПЕРВЫМ** (до anticipation по флагам), поэтому resolved-источник физически не может заявить AirPods, пока роут — встроенный мик. `MicSourcePicker.computeEffective()`:
- **во время записи** (`isActive`) — зеркалит `currentMicSource().kind` (реальный роут, истина);
- **в idle** — anticipation по target-флагам: lock ON → iPhone; явный BT-override + AirPods подключены → AirPods; иначе iPhone. «BT подключён для музыки» idle-галочку на AirPods НЕ ставит (та же ложь — дефолтная категория с них не пишет; AirPods включаются только явным пиком, который флипает категорию на HFP).

Picker подписан на `micSourceDidChange` (менеджер постит его на каждый settle реального роута), поэтому badge обновляется **и во время записи** — собственный `onReceive(routeChange)` пикера намеренно `guard !isActive` (чтобы не реагировать на наши же category-флипы), и без подписки на `micSourceDidChange` badge висел бы замороженным всю запись.

## Live-свитч микрофона в обе стороны: `reapplyLiveTarget`

Свитч мика во время записи идёт через единый `AudioSessionManager.reapplyLiveTarget()` — он флипает категорию если отличается + пинит нужный порт под текущие `forceBuiltInMic`/`wantsBluetoothMic`. Раньше re-route был только в сторону AirPods (внутри `selectInput`); пик «iPhone обратно» лишь ставил override-флаг и обновлял локальный UI, но **не** трогал живую сессию → badge говорил iPhone, а HFP держал AirPods-мик (тот же display-vs-reality, зеркально). Теперь обе ветки `pick()` при `isActive` зовут `reapplyLiveTarget`; смена input-порта (HFP↔builtInMic) триггерит `onActiveRouteChange` → `MicCaptureHub.rebuildTap` на свежем sampleRate (см. `::MicCaptureHub` и секцию про tap rebuild). Completion на main гасит loader и зовёт `refresh()`, который подтверждает badge **из реального роута** — если HFP-handshake не удался и роут остался на iPhone, badge покажет iPhone (правда, а не намерение).

## Детерминированный fallback при отключении AirPods mid-record

Юзер-требование: «выбрал AirPods, потом отключил — чтобы детерминированно показывало iPhone, а не висели AirPods». Research (Perplexity, см. ниже) подтвердил подводный камень: если BT-устройство было пиннуто **явным** `setPreferredInput`, его отключение может НЕ выстрелить `.oldDeviceUnavailable` чисто (иногда сразу `mediaServicesWereLost`); если же роут был implicit (`preferredInput == nil`) — iOS грейсфулли шлёт `.oldDeviceUnavailable` и сам падает на встроенный мик.

Наш `handleRouteChange` на `.oldDeviceUnavailable`: если стоял BT-override и `btOutputDevice() == nil` (устройство реально ушло) — **сбрасываем `preferredPortOverride = nil`**. Иначе `wantsBluetoothMic` остался бы true с несуществующим устройством: badge висел бы на AirPods, а следующая запись пошла бы по HFP-категории (без `.mixWithOthers` → глушит музыку) ради мика которого нет. После сброса — единоразовый `reapplyLiveTarget()` (гейт по `clearedBTOverride`, чтобы не слать `setCategory` на каждый route-change и не эхо-генерить свой же `categoryChange`), категория возвращается на A2DP-only iPhone-путь.

## Выбор встроенного мика: Bottom / Front / Back через dataSources

Юзер хочет выбирать **какой физический встроенный микрофон** пишет (как в diktofon-аппах): нижний у разъёма, верхний/фронтальный у ушка, задний у камеры. У iPhone 15 Pro/16 это три hardware-мика, доступные не как отдельные порты, а как **data sources** одного `builtInMic` порта.

**API:** `port.dataSources` (массив `AVAudioSessionDataSourceDescription`) у `builtInMic`-порта из `availableInputs`; выбор — `port.setPreferredDataSource(_:)`. Классифицируем в `MicDataSource{bottom,front,back}` по `ds.orientation` (`.bottom`/`.top`/`.front`/`.back`), с фолбэком на `dataSourceName` («Bottom»/«Front»/«Back»). Только `builtInMic` несёт data sources — у AirPods/USB их нет, поэтому карточка показывается лишь на iPhone-мик-пути и когда `availableMicDataSources().count > 1`.

**КОНТРИНТУИТИВ — `.measurement` mode саботирует выбор.** Наш iPhone-путь по умолчанию `.measurement` (чистый capture). Research (Perplexity): *«.measurement minimizes audio processing and **often forces the primary bottom microphone, overriding custom data source selections**»*. То есть под `.measurement` любой `setPreferredDataSource(.front/.back)` молча откатывается на нижний мик. Решение: `categoryMode` отдаёт `.default` когда `preferredMicDataSource != nil` (а не `.measurement`), и `selectMicDataSource` при живой сессии переустанавливает категорию с новым mode перед пином источника. Без этого выбор «Верхний» визуально срабатывал бы, но писал бы нижним.

**Не персистит через route change.** Research: выбор data source сбрасывается при любой смене роута (воткнули наушники и т.п.). Поэтому sticky-намерение в `preferredMicDataSource` (App Group, как `forceBuiltInMic`), и `reapplyMicDataSourceIfNeeded()` вызывается в `handleRouteChange` после re-pin'а input'а + в `activate()` после `setPreferredInput`.

**Бейдж капсюля = НАМЕРЕНИЕ (`preferredMicDataSource`), а НЕ живой роут.** Симптом юзера: «выбираю Верх/Зад — галочка не встаёт, ничего не происходит; один раз только Низ выбрался; а как начал запись — вдруг отобразился задний; после стопа снова никак, помогает только перезапуск приложения». Корень: `setPreferredDataSource` физически попадает в `currentRoute.selectedDataSource` **только когда идёт аудио-I/O** (движок крутится). В idle и между записями (always-active: сессия active, но движок остановлен) роут отражает дефолтный нижний капсюль. Поэтому `refresh()`, читавший роут, откатывал галочку на «Низ» — выбор будто не срабатывал; а на старте записи I/O оживало и роут наконец совпадал с намерением. **Что пробовали (и почему неверно):** читать `currentMicDataSource()` (= `currentRoute...selectedDataSource`) как истину для бейджа — это и был баг. **Решение:** карточка показывает `preferredMicDataSource` (sticky-намерение, пишется синхронно в `selectMicDataSource` до любого async), фолбэк на роут только когда явного выбора ещё нет (состояние «Авто»). Намерение = то, что юзер выбрал и что применится; роут — лишь его поздняя проекция при живом I/O.

**Mid-record switch РАЗРЕШЁН (карточка enabled во время записи).** Раньше карточку `.disabled`'или пока идёт запись — по research'у «смена data source mid-record не бесшовна, рвёт I/O». На практике рвётся не катастрофично: Низ/Перед/Зад — **один и тот же порт `builtInMic` на той же частоте**, меняется лишь капсюль, ресэмплеру ничего не грозит. Реальная заминка — это флип `categoryMode` `.measurement→.default` (когда впервые пиннится источник): он реконфигурирует граф, движок сам себя останавливает. `MicCaptureHub` подписан на `AVAudioEngineConfigurationChange` (object = engine) и на это событие **пересобирает tap + рестартит** (тот же путь, что route-change rebuild, с re-entrancy guard `isRebuilding`, т.к. `engine.stop/start` сами постят это уведомление). Захват продолжается за ~100ms gap. Поэтому карточка больше НЕ дизейблится — менять капсюль можно и в idle, и mid-record.

**Один data source на ВСЕ записи — `micDataSourceDidChange`.** Железно: одна сессия → один input route → один выбранный капсюль. Параллельные диктовка+long пишут с **одного** капсюля; «отдельный мик на каждую запись» физически невозможен. Но пикеров два (нижний ряд + зеркальный в long-панели), и при смене в одном второй показывал **устаревшее** значение — создавая иллюзию двух раздельных настроек. Корень: существующий `micSourceDidChange` дедупится по `(kind, name)`, а смена капсюля не меняет пару (остаётся `iphone`/«Микрофон iPhone») → уведомление не постилось. Решение — **отдельная** нотификация `micDataSourceDidChange`, постится в `selectMicDataSource` сразу после записи намерения; оба `MicSourcePicker` на неё подписаны и `refresh()`'атся. Инвариант: оба пикера всегда показывают один общий выбор.

## Polar patterns + перекрытие мика: что выяснили (graveyard, не переизобретать)

Юзер хотел «режим, который ловит звук со всех сторон» (для круглого стола 5 человек). Разобрали через device-probe (временный, выпилен после) — выводы как graveyard, чтобы не лезть туда снова.

**Omnidirectional УЖЕ дефолт на всех трёх капсюлях — отдельный «omni-режим» бессмыслен.** Probe на конкретном iPhone 15 Pro: `selected=Omnidirectional` у Низ/Перед/Зад одновременно. Полярные паттерны (`.omnidirectional`/`.cardioid`/`.subcardioid`/`.stereo`) — это beamforming, который iOS считает из встроенных капсюлей, **НЕ** доступ к «нескольким сырым микрофонам разом» (приложению отдаётся ОДИН input-канал, 3 капсюля живут под Apple-процессингом — «прочитать все три и смешать самому» невозможно). `.omnidirectional` = «выключи beamforming, лови ровно отовсюду» — и это и есть текущее поведение при выборе любого капсюля. Добавлять 4-ю кнопку «Omni» — дублировать дефолт, юзер не увидел бы разницы. Для стола правильный выбор — просто **«Верх»** (Front-капсюль смотрит вверх с лежащего на столе телефона, открыт в комнату), а не особый режим.

**`supportedPolarPatterns` непуст ТОЛЬКО под mode, разрешающим выбор паттерна** (`.default`/`.videoRecording`). Под нашим дефолтным `.measurement` массив **пустой** — выглядело бы как «не поддерживается». Probe это и форсил `.default` на время чтения. Доступность паттернов — device- и data-source-specific: на этом устройстве Front нёс `[Omni,Cardioid,Stereo]`, Низ — только `[Omni]`. Если когда-нибудь делать выбор паттерна — флипать mode обязательно.

**iOS НЕ авто-переключает мик при перекрытии пальцем.** Юзер был уверен: «закрыл нижний — звук сам пошёл с верхнего». Детерминированный probe-лог (раз в секунду печатал живой `selectedDataSource` всю запись) опроверг: капсюль **держался выбранным всю запись**, ни одной смены. Такого механизма у iOS нет (`RouteChangeReason` — фиксированный enum, нет reason'а «mic occluded»). «Восстановление звука через ~секунду» = **AGC** накрутил усиление тому же закрытому капсюлю (глуше + шумнее, но тот же мик). Выбор Низ/Перед/Зад — **жёсткая позиция** (лог подтвердил, держится намертво), не «мягкий приоритет».

**Почему закрытый мик всё равно пишет** (физика, для будущих вопросов): (1) палец не герметичен — звук затекает в щели; (2) **structure-borne** — корпус вибрирует от звука и достаёт мембрану в обход отверстия; (3) на iPhone 15 Pro низ симметричен, но **слева мик, справа динамик** (мик в USB-C-сборке) — юзер мог давить на динамик/симметрию, а мик-порт рядом открыт; (4) AGC добивает громкость. Задний капсюль (одиночная дырка на гладкой спинке) перекрывается пальцем **герметично** → «вырубается»; нижний — рядом куча щелей (порт, грань, решётка динамика) → не глушится. Разница в наблюдении юзера — это **геометрия перекрытия**, не «разное усиление» (AGC крутит гейн одинаково для любого капсюля).

## Output-выбор динамика (speaker/receiver): пробовали, убрали — graveyard

**Не переизобретать output-picker для рекордера.** В этой сессии добавили карточку выбора динамика (громкий `.builtInSpeaker` ↔ ушко `.builtInReceiver` через `overrideOutputAudioPort`) и затем **удалили целиком**: при записи звук никуда не выводится, выбор выхода для voice-рекордера бессмыслен (юзер: *«выбор динамика вообще нахуй не нужен»*). Заменено на выбор встроенного мика (input) — см. секцию выше. Принцип — `methodology/переносимый-дизайн.md::Выбирать дают то, что относится к задаче`.

Verified-факты из research (Claude deep, 269 источников) сохраняем как graveyard — если снова потянет сделать output-выбор:
- **`AVAudioSession.PortOverride` имеет РОВНО два кейса — `.none` и `.speaker` (НЕТ `.receiver`)**; `overrideOutputAudioPort` действует только в `.playAndRecord`. Общего `setPreferredOutput` в iOS НЕТ. То есть максимум что доступно — «громкий нижний ↔ дефолт», передний/задний динамики Pro апп НЕ адресует (стерео-сплит системный).
- **`.measurement` отключает `.defaultToSpeaker`, но runtime `overrideOutputAudioPort(.speaker)` работает поверх mode** — поэтому `.defaultToSpeaker` в `categoryOptions` не кладём (бесполезен + может перебивать BT-output).
- **Авто-failover «сломанного»/закрытого динамика в iOS НЕТ.** `AVAudioSession.RouteChangeReason` — фиксированный enum без reason'а «speaker health»; route меняется только от аксессуаров и наших override.

## Blocking API: setCategory / setActive / setPreferredInput — обязательно на serial queue

Apple SDK header для `AVAudioSession`: *«Note that activating an audio session is a synchronous (blocking) operation. Therefore, we recommend that applications not activate their session from a thread where a long blocking operation will be problematic.»* То же relevantно для `setCategory` и `setPreferredInput` — они идут через тот же synchronous IPC к mediaserverd. На Bluetooth-роуте это 1-3 секунды wait'а на handshake.

Если эти вызовы на main thread — UI замерзает, пикер выглядит сломанным (часто симптом «пункт меню исчез»). В `AudioSessionManager` всё это уехало на dedicated `audioQueue: DispatchQueue` с `qos: .userInitiated`. Public API асинхронный (`activate(completion:)`, `selectInput(_:completion:)`, `probeInputs(completion:)`) — completion на main, для UI loader'а.

Apple QA1715 дополнительно: render callback (real-time thread в Remote I/O Audio Unit) **никогда** не должен звать AVAudioSession API — они блокируют. У нас render-side только resampling, никаких session-touch'ей.

## Прерывание сессии → восстановление захвата (и самолечение AVFAudio -50)

**Симптомы:** (1) «жёлтое предупреждение нет-интернета, кнопка мика красная, говорю-говорю, а звук дальше не записался»; (2) «после прерванной/недозавершённой записи жму Старт — `The operation couldn't be completed. (com.apple.coreaudio.avfaudio error -50.)`, и так до перезапуска приложения». Оба — про **сорванную сессию, из которой код не восстанавливался**, а НЕ про сеть: `allFrames` (источник `.wav`) копится пока не нажат Стоп, независимо от WS, так что чистый обрыв Soniox запись не рвёт.

**Корень — пустой `case .began: break` в `handleInterruption`.** Когда система деактивирует сессию (звонок, Siri, будильник, чужое приложение схватило немиксуемый роут — иногда совпадает с сетевым сбоем), она ОСТАНАВЛИВАЕТ и наш движок. Старый код на `.began` не делал ничего → флаг `isActive` залипал `true`. Дальше два следствия: (а) `.ended` реактивировал только сессию, но не движок/тап → «кнопка красная, но не пишет»; (б) на следующем старте idempotency-guard в `activate()` (`if isActive && категория совпадает → skip setActive`) пропускал реальный `setActive(true)` → `engine.start()` отдавал **-50** до перезапуска процесса (свежий процесс имеет `isActive=false`, потому рестарт и «лечил»).

**Решение — сессия и движок переживают любое прерывание, чинятся сами:**
- `.began`: сразу `isActive = false` (чтобы guard не пропустил реактивацию) + хук `onInterruption(true)`.
- `.ended` / `mediaServicesWereReset`: `onInterruption(false)` → `MicCaptureHub.resumeCaptureAfterSessionLoss` зовёт **`reactivateHard`** (форсит реальный `setCategory+setActive` в обход guard'а, сбросив флаг) и перезапускает движок+тап. НЕ гейтим на `.shouldResume` — живую запись возвращаем всегда (правило юзера «останавливает только Стоп»).
- `engine.start()` бросил (обычно тот самый -50 от системно-деактивированной сессии) → **hard-reactivate + один retry** прямо в `MicCaptureHub.startEngine`, вместо ошибки-до-перезапуска.
- **Watchdog 2с** (`captureWatchdog`) на `engine.isRunning` пока есть активный сток: прерывания НЕ гарантируют доставку `.ended` (Apple это документирует — совпавший route-glitch / фоновое приложение могут оставить нас остановленными без события), поэтому молчаливую смерть движка ловим опросом. Re-entrancy guard `isResuming` сериализует `.ended` и watchdog (каждый `reactivateHard` уходит на audioQueue async — два восстановления гонялись бы за `engine.start()`).

`reactivateHard` нужен именно потому, что после системной деактивации `session.category` всё ещё читается `.playAndRecord` — обычный `activate()` бы short-circuit'нул и не реактивировал. Это единственная точка «сделай сессию реально живой заново» для всех путей восстановления. Переносимый принцип («сбой зависимости ≠ стоп записи») — `methodology/переносимый-дизайн.md::Сбой зависимости не останавливает запись`. User-flow — `methodology/сценарии-использования.md::in-app start/stop` (Edge: прерывание/потеря сети).

## probeInputs steals audio route — single-shot pattern

`probeInputs()` нужен потому что iOS не публикует `session.availableInputs` пока сессия не имеет категории + активации. То есть «открыли Voice tab, хотим увидеть список устройств» требует `setCategory + setActive(true)`. Эта пара перехватывает аудио-роут у backgrounded music app на ~1с (тот же hardware flush). На каждое открытие Voice tab дёргать probe — означает каждый раз обрывать музыку.

Решение: `hasProbedThisLaunch` гвард в менеджере. Probe выполняется максимум один раз за жизнь процесса. После этого `currentRoute.outputs` достаточно для UI badge'а и BT-детекции (см. секцию выше).

Реальный сценарий регрессии (без гвaрда): пикер re-probe'ил на каждый `AVAudioSession.routeChangeNotification` → probe сам генерит routeChange (reason `.categoryChange`/`.routeConfigurationChange`) → бесконечный loop, в логах стена `[Audio] [probe]` каждые ~80ms.

## Idempotency guard для setPreferredInput

`setPreferredInput()` сам по себе постит `routeChangeNotification` (reason `.categoryChange` или `.override`). Наш handler `handleRouteChange` зовёт `applyPreferredInput()` → который зовёт `setPreferredInput()` → новая нотификация → ∞ loop, main thread заблокирован, UI фризится на секунды.

Защита в `applyPreferredInput`: перед `setPreferredInput(chosen)` сравнить `session.preferredInput?.uid == chosen?.uid` → если совпадает, return. Цикл обрывается на первой итерации. То же на пикере: `onReceive(routeChange)` whitelist'ит только `.newDeviceAvailable` / `.oldDeviceUnavailable` — реальное подключение/отключение железа. Category/config-changes игнорируются (мы их сами и генерим).

## Route change mid-recording: tap rebuild с новым sampleRate

Когда юзер подключает/отключает AirPods **во время** записи, iOS переключает audio route, и **input format меняется** (built-in iPhone обычно 48kHz, AirPods HFP 16kHz, hi-q recording 48kHz). Старый input tap был installед с captured `format` от прошлого устройства, `sourceRate` зафиксирован в closure'е. Resampler `floatToS16LE16k` использует этот старый rate против нового реального — на выходе chipmunk-effect или slow-motion аудио, транскрипт garbled.

Фикс: `AudioSessionManager.onActiveRouteChange` callback. Подписан **`MicCaptureHub`** (раньше — `DictationSession`; перенесено в хаб, чтобы при двух параллельных стоках был ОДИН rebuild на общий движок, а не два конфликтующих). При срабатывании: `engine.stop()` → `removeTap` → `installTap()` (читает свежий `inputNode.outputFormat(forBus: 0)`) → `engine.prepare()` → `engine.start()`. Собранный PCM у каждого стока в его `allFrames` сохраняется — транскрипт непрерывен за ~100ms gap. Стоки про смену rate не знают, получают чистый 16kHz. Без restart'а — `AVAudioEngineConfigurationChangeNotification` всё равно прилетит, engine сам затихнет, но format будет stale → silent ошибка.

## Связанное

- `fact-voice-record.md` — overall Voice subsystem, killed-state Toggle.
- `fact-live-activity.md` — `.ended` pop-out перед dismiss использует тот же `setActive(false)` deactivate-в-end()-flow.
- `fix-background-intent-crashes.md` — почему deactivate обязателен на background-intent stop пути (jetsam 0x8badf00d).
