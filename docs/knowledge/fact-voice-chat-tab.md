# Fact: нативная вкладка AI Chat к voice-record

Вкладка **AI Chat** (первая в таб-баре, перед Voice) — нативный SwiftUI-клиент того же
агента, который живёт в macOS-приложении Voice Record. Это больше НЕ WKWebView к
`mobile-web`: веб-слой был заменён на `VoiceChatStore.swift` + `VoiceChatUI.swift`, а
`VoiceChat.swift` оставлен для config/API и prompt picker. Сервер и протокол — в
`voice-record/docs/knowledge/fact-mobile-bridge.md`; MCP/bash/file tools исполняются на
Mac, телефон только управляет turn'ами и показывает REST/SSE-состояние.

Код: `HabitTracker/VoiceRecord/VoiceChat.swift` (config, low-level API, prompt picker),
`VoiceChatStore.swift` (REST/SSE singleton, conversations, running, confirms, bypass),
`VoiceChatUI.swift` (list/detail/composer/cards/settings). Кнопка/шит отправки из Voice —
`Views/VoiceRecord/VoiceRecordTabView.swift` и history rows в
`Views/VoiceRecord/TranscriptHistoryView.swift`; навигация — `VoiceRecord/TabRouter.swift`.

## Почему нативный клиент, а не вебвью

Старая модель была «AI Chat = `WKWebView` к `voice-record` mobile-web». Она дала быстрый
старт, но для текущей роли телефона важнее нативные состояния: toolbar By-pass, inline
confirm cards, long-press context menu, native offline screen, SwiftUI navigation и общий
App-Group defaults. Удаление WebView не меняет доступ к инструментам: источник возможностей
— Mac-side `runAgent`, а не renderer. Поэтому legacy Remote-код остаётся WKWebView к
custom-terminal только как отладочная/конфигурационная обёртка, а AI Chat — нативный клиент к
voice-record REST/SSE плюс нативный Terminal mode к custom-terminal REST/SSE.

## Terminal mode внутри AI Chat

AI Chat теперь мультиплексирует два удалённых продукта в одном нативном контейнере: обычный
Voice Record chat (`VoiceChatStore`) и custom-terminal control (`TerminalControlStore`). В
левом history drawer строка **Terminal** находится под **Chats**; тап переводит центральную
область из chat detail в terminal root, но drawer/swipe-навигация остаются теми же. Если
пользователь свайпнул в историю и выбрал обычный AI Chat, `terminalMode=false`; если снова
нажал Terminal — возвращается к terminal-поверхности. Это mode внутри вкладки AI Chat, а не
четвёртая root-вкладка.

Terminal root имеет три уровня: список проектов custom-terminal → список вкладок проекта →
нативный чат выбранной Claude/Codex/SDK вкладки. Project list берёт `/api/projects` и
показывает project icon из custom-terminal, а не folder-only fallback; это важно для parity
с desktop проектами. Порядок этого списка тоже приходит с сервера: открытые проекты идут
как project tabs на desktop слева направо, только на телефоне сверху вниз; закрытые проекты
идут ниже. iOS не пересортировывает ответ по `updatedAt`, иначе мобильная навигация начинает
жить своей логикой и расходится с тем, как пользователь уже разложил рабочие проекты на Mac.
Если у проекта нет icon, fallback folder остаётся чёрно-белым; прозрачный PNG icon сидит на
нейтральном сером фоне, не на Codex-green — зелёный зарезервирован для runtime/agent
semantics. Active-count badge (`N`) и ring-loader рисуются напротив названия каждой
директории/проекта, а не рядом с кнопкой Terminal в header: пользователь смотрит на строку
директории и должен сразу видеть, где сейчас идёт работа. Список вкладок берёт
`/api/projects/:id/tabs` и разделяет две оси: agent icon слева (Claude/Codex SVG asset)
показывает тип движка, assigned status marker рядом с первой строкой показывает
пользовательскую категорию вкладки, runtime status (`starting/active/busy/inactive`)
рисуется точкой/loader'ом и фоном строки. Session id в строке не показывается: это
debug-поле, которое пользователь не выбирает глазами.

Кнопка **New Terminal** — floating action справа снизу, как **New Chat** в истории. Она
открывает sheet с первичными действиями Codex и Claude; Claude SDK спрятан в ellipsis menu,
потому что это не основной mobile-terminal сценарий. Создание Claude/Codex идёт через
custom-terminal `/api/projects/:id/agent-tabs`, чтобы Mac-side renderer создал ordinary
PTY-tab с `pendingAction` тем же путём, что desktop. iOS не пишет команды в PTY сама.

Кнопка install в правом верхнем углу Terminal root — не refresh. Refresh как web-метафора
здесь обманчив: экран нативный, а данные всё равно обновляются через store. Install
сначала спрашивает custom-terminal `/api/active-loaders`; если хоть одна вкладка реально
стримит/исполняет процесс, показывается блокирующий alert с проектом/вкладкой/cwd/command
и confirm не открывается. Если блокеров нет, iOS запускает job через Voice Record
`/api/terminal/build-install`, потому что сам custom-terminal во время `build:install`
закрывается и не может быть управляющим процессом. Loader живёт только на toolbar-кнопке;
если Terminal в это время недоступен, нижняя часть экрана остаётся в обычном offline-state.

`TerminalControlStore.start()` греет cache проектов и вкладок при запуске приложения и при
возврате в foreground: `/api/projects`, затем тихий prefetch `/api/projects/:id/tabs` для
проектов с вкладками/open-state. Это навигационный cache, не preload transcript'ов: истории
Claude/Codex читаются только при входе в конкретный tab, потому что history имеет отдельные
детерминированные JSONL/rollout правила и намного тяжелее проекта/списка вкладок.
Позиция списков тоже store-owned: root project list хранит последний видимый project id, а
каждый project tabs list — последний видимый tab id. При переходе `проекты → директория →
чат → назад` SwiftUI view может пересоздаться, но `scrollPosition(id:)` восстанавливает
ближайший row вместо сброса списка наверх. Это только навигационная память списков, не
preload/scroll-memory transcript'ов.

В chat detail лента рендерится нативно: user/assistant/thinking/tool/slash/compact-summary
нормализуются из custom-terminal history endpoint. Composer похож на Voice Chat composer по
layout, но кнопка микрофона отсутствует; снизу остаются params, два prompt picker'а
(Voice prompts и terminal prompts), GT file chips, send/interrupt. Terminal prompts
обозначаются `TerminalIcon`, не буквами `VG`: буквы не объясняют источник prompt'ов на
мобильном экране. Model и effort открываются compact dropdown'ами от самих chips (без
leading-иконки и без `chevron.down` — в узком composer'е глифы съедают ширину, а меню
очевидно по тапу); think — не dropdown, а toggle-иконка мозга в long-press меню заголовка
вкладки (детали — `::Terminal model/effort/think`). Hide-keyboard и scroll-to-bottom
повторяют chat accessory row: кнопка вниз стоит по центру снизу над composer, а скрытие
клавиатуры — отдельной кнопкой справа. Run-after и Timeline — floating controls в правом
верхнем углу поверх ленты, а не flow-блок над чатом: это короткие инструменты текущего tab,
они не должны отнимать вертикальное место у transcript.

Live-state не живёт во view. `TerminalControlStore.shared` держит проекты, tabs, history,
params, queue, timeline, SSE и runtime status отдельно от `VoiceChatStore.shared`. При
открытом tab SSE `snapshot/busy/done/queue-update/bridge-update` обновляет runtime сразу,
а для history есть canonical reload после `message`/`done`: если текущая лента пришла из
нормализованного `/history?view=history`, raw SSE message не пытается вручную мержиться в
этот shape, а планирует короткую перезагрузку истории. Это исправляет симптом «история
обновляется только если выйти из вкладки и зайти обратно» и сохраняет тот же
детерминированный JSONL/rollout contract, который использует custom-terminal History.

Send/interrupt draft recovery тоже живёт в store, не во view. После отправки Terminal mode
помнит только факт «этот turn recoverable», но не использует last-sent text как источник
восстановления. Если пользователь быстро жмёт Stop, `TerminalControlStore` ждёт
детерминированный reason (`interrupt`, `turn_aborted`, `catch-up-turn_aborted`), затем
делает probes custom-terminal `/api/sdk-tabs/:id/draft`; только фактический TUI draft
возвращается в composer. Если draft пустой, показывается нейтральное notice. Это зеркалит
desktop `Cmd+\` History и предотвращает регрессию «prompt возвращается вручную/рандомно,
а не по JSONL/rollout событию».

Back-swipe внутри Terminal потребляется локальной иерархией: chat detail → список вкладок
проекта → список проектов. Только когда Terminal уже на root, тот же left-edge gesture
передаётся AI Chat drawer/history. Иначе жест с экрана чата неожиданно открывал бы общий
список AI-чатов вместо ближайшего родительского уровня Terminal. Внутренний переход назад
коммитит `store.stepBackOneLevel()` только в completion самой slide-анимации; `Task.sleep`
или фиксированный delay даёт видимый double-jump: старая поверхность уже доехала, затем
предыдущий список появляется второй раз как новый layout. Тот же horizontal drag обязан
временно гасить row taps: SwiftUI `simultaneousGesture` сам не отменяет `Button` release под
пальцем, поэтому без `terminalSelectionSuppressed` свайп вправо по списку проектов/вкладок
мог после отпускания открыть директорию или чат, хотя пользователь делал навигационный жест.

## Terminal navigation: custom slide, snapshots, logs

Три уровня Terminal (`projects → project tabs → chat`) не являются `NavigationStack` push'ами.
Это один custom horizontal container: текущая поверхность и destination/preview слои двигаются
через `.offset(x:)`, а commit выбранного проекта/таба делается только в completion анимации.
Из-за этого любые живые `@Observable` reads внутри moving layer считаются частью анимации:
статус-poll, SSE snapshot или tabs-prefetch могут пересобрать subtree ровно в кадр slide'а.
Инвариант: слой, который едет, рендерится из value snapshot и не читает store. Back-preview
снимает `projects`/`tabs` в value-модели на `begin drag`; forward project→tabs использует
static tabs snapshot; forward tab→chat показывает placeholder header, а live transcript
монтируется только после commit.

Проект→tabs отдельно держит лёгкую transition-поверхность. Даже 3-10 строк могут давать
`worst=44-59ms`, если во время slide тащить `ScrollView + TerminalTabRow + AgentIconView +
glass refresh + contextMenu/FAB`. Поэтому forward snapshot использует simplified row:
статичный SF Symbol вместо asset lookup, точка runtime вместо spinner, без `ScrollView`,
refreshable, context menu и floating action. Live `TerminalProjectTabsView` пока
`interactionsSuspended` тоже сначала показывает тот же дешёвый список; полные controls
появляются уже в `settle`, после навигационного кадра.

Логи этой навигации должны читаться по `nav#`, а не по соседним строкам. `FrameMonitor` пишет
окно `reason=term-nav label="pushProject ..."` / `back from=chat` и фазы
`mount / animate / swap / settle`; `MainThreadWatchdog` пишет `[hang]` только если main
реально не отвечает; `TerminalRenderProbe` пишет `row bodies/distinct/burstMs` с тем же
`nav=`. Диагноз по ним: если `cachedTabs=true fresh=true skip tabs reload`, а frame-window
всё равно дорогой — это render/commit поверхности, не сеть; если `history publish WAIT` и
`DROP after wait` срабатывают при back-swipe — history не публикуется в анимацию; если
`row bodies==distinct` без повторов — это не body-churn storm.

## Store singleton — источник правды, не view-state

`VoiceChatStore.shared` живёт на жизнь приложения. Running-state берётся из двух источников:
серверный `/api/chats?limit=50` (`running:true`) и live SSE `user/done/error/cancelled`.
Это специально не `@State` внутри detail view: вкладка может исчезнуть, пользователь может
уйти в Voice/Remote, SSE может зомби-зависнуть в фоне. `start()` идемпотентно reconnect'ит
SSE при stale stream, refresh'ит список и rehydrate'ит running-чаты через
`GET /api/chats/:id`. Pending confirm cards тоже серверные (`pendingConfirms`) и мержатся
с локальными tombstones, чтобы stale GET не воскресил уже answered/resolved карточку.

Логи нативного клиента идут через `VCLog.log(tag,msg)` в два места: батч `POST /api/log`
на Mac → `~/Library/Logs/voice-record/ios-chat.log` и локальный ring-buffer на телефоне,
доступный в AI Chat Settings → Diagnostics → Show debug log / Copy. При симптомах
«карточка не появилась», «By-pass не сработал», «первый tap по input не фокусит» или
«клавиатура едет не вместе с composer» грепать рядом оба Mac-файла (`ios-chat.log` с
локальным временем телефона и `voice-record.log` в UTC) и/или просить локальный diagnostics
copy из settings. Важные теги: `[SSE]`, `[Store]`, `[Confirm]`, `[Keyboard]`.

## Offline-state прямо в Chat detail

`VoiceChatStore.offline` — глобальное состояние недоступности Mac-side Voice Record, а
не только decoration для history/drawer. Если load/send получает network failure,
HTTP 0 или 503, store включает offline и запускает retry; detail view заменяет
транскрипт центральным блоком “Mac недоступен”, дизейблит composer и убирает клавиатуру.
Иначе пользователь видит недоступность только в истории, но остаётся в конкретном чате
с активным input и может нажать Send в заведомо нерабочий backend.

Failed send обязан вернуть draft назад полностью: не только `input`, но и выбранные
`gtAttachments`. Иначе самый опасный путь — юзер прикрепил GT-файл, сеть умерла,
текст вернулся, а файл-чип исчез; следующий retry уходит без файла и агент не видит
контекст. Это та же пользовательская модель, что у server-side rollback: если turn
не стартовал успешно, composer должен выглядеть как до нажатия Send.

Тот же offline guard стоит на кнопках **Chat** в Voice main и History row: если Mac-side
чат недоступен, кнопка визуально приглушена и обработчик сразу выходит. Иначе пользователь
может нажать отправку диктовки в backend, который уже известен как недоступный, и получить
ложное ощущение, что текст ушёл в чат.

## Handoff openChat: реагировать на ОБА сигнала, дедуп по токену

Шрам гонки. Наивно `openChat(id)` ставил `pendingChatId` затем `selected=.chat`, а таб ловил
только `onChange(of: pendingChatId)` с guard `selected==.chat`. Порядок доставки двух
`@Published` не гарантирован — в момент смены `pendingChatId` поле `selected` ещё `.voice` →
guard не проходит → **переход в чат теряется**, показывается старый разговор. Симптом
(юзер): *«переход в чат не происходит / показывает прошлый»*. Лечение: запрос —
UUID-штампованный токен (`ChatRequest{seq, chatId}`), таб реагирует на ОБА сигнала
(`onChange(pendingChatRequest)` И `onChange(selected==.chat)` И первый `onAppear`), а
`consumePending` дедупит по `seq` — загрузка отрабатывает ровно один раз, кто бы из сигналов
ни пришёл первым. UUID-токен ещё и различает «открыть чат `nil`=список» от «нет запроса».

## Кнопка Chat встречается с вкладкой на сервере

Кнопка **Chat** на Voice-экране и в карточках истории не инжектит state в открытую вкладку.
Она нативно POST'ит `/api/chat/send` (URLSession + bearer, зеркало `SonioxTokenMint`),
получает `chatId`, затем `router.openChat(id)` переводит пользователя в AI Chat. Вкладка
открывает этот id через store: `loadConversation` + общий SSE. Точка встречи — серверный
conversation id; нативный Swift↔Swift мост между Voice и Chat для содержимого не нужен.
Сам путь юзера — `methodology/сценарии-использования.md::Chat из Voice-экрана`.

## Пикер промптов self-loading

Пикер промптов сам себя грузит: sheet презентится сразу со спиннером, тянет `/api/prompts`
в `.task`, кеширует в локальном state, есть retry. «Отправить без промпта» — первая строка,
а не pinned-bottom action: это самый частый быстрый путь из Voice в Chat. Наивная версия,
где родитель ставил `chatPrompts` и тут же `showPromptPicker=true` в одном async-тике,
давала sheet с **пустым**
снимком — SwiftUI презентил до того, как state долетел. Правило шире: sheet с сетевыми
данными грузит их внутри себя по факту презентации, а не получает готовыми от родителя,
который выставляет данные и флаг показа одновременно. Это bottom-sheet
(`.presentationDetents([.medium,.large])`), не fullscreen — выбор промпта лёгкое действие.

У пикера две поверхности. Когда он открыт с Voice-экрана или из history row записи, header
показывает model-chip, think-chip и текстовую кнопку `Switch`: в этом месте пользователь
прямо выбирает, какой связкой отправить диктовку в новый чат. Когда тот же picker открыт из
composer внутри AI Chat (`Prompt`), header скрыт: model/think/Switch уже видны в composer,
а prompt picker должен быть только выбором prompt'а. Иначе один и тот же mode-control
дублируется на дочерней поверхности и выглядит как три лишних пункта.

Выбор prompt'а в этих поверхностях коммитится по-разному. Voice/history picker — это действие
«отправить диктовку в новый чат», поэтому leaf prompt сразу закрывает sheet и POST'ит
`/api/chat/send`. Picker внутри уже открытого AI Chat — это подготовка текущего draft:
leaf prompt превращается в фиолетовый prompt-chip над composer, не отправляет turn и не
закрывает логику чата. Send активен даже при пустом input, если есть prompt/GT-chip. Prompt
уходит на сервер как top-level `promptId/variationId`, а не как обычный attachment: Mac-side
сервер сам резолвит его в prompt chip + instruction text. Иначе «чип есть, но нейронка не
знает файл/промпт» повторится как silent-drop контекста.

## GT Editor файлы как composer chips

Кнопка `GT` в composer открывает native sheet `VoiceChatGTFilePicker`: источники и дерево
загружаются через Voice Record `/api/gt/*`, а тот проксирует local API GT Editor. iOS не
знает порт GT Editor и не читает его БД напрямую; это важно для телефона вне Mac loopback.
Файл прикрепляется как `VCAttachment(kind:"gtfile", filePath, reread:true)` — path-only
чип, который Mac-side агент перечитает через `read_file` при `runAgent`.

Tap по файлу — быстрый single-add: чип добавляется, sheet закрывается, пользователь сразу
видит файл над composer. Long press — multi-add режим: файл помечается серым/галочкой,
даёт native-like press animation + haptic, sheet остаётся в текущей директории, можно отметить ещё несколько файлов без повторного
прохождения пути. Это мобильный аналог desktop `+` справа в строке файла; обычный tap не
должен превращаться в multi-select, потому что самый частый путь — один файл и закрыть.

Directory-source в sheet подписывается просто как «директория»: tab-count там намеренно не
показывается, потому что пользователь выбирает из файлового дерева, а не из вкладок. После
прикрепления `gtfile` отображается как GT-glyph chip; тап по уже прикреплённому чипу открывает
preview через `/api/gt/file?includeContent=1`, чтобы пользователь мог проверить содержимое
path-only вложения до отправки.

Preview рендерит GT markdown, а не plain text. `@ai` читается как многострочный
comment-блок до закрывающего `-->` и показывается отдельной красной AI-карточкой;
indentation отображается настоящими вертикальными линиями на высоту строки/блока,
а не текстовым символом `│`. Для custom emoji preview дополнительно читает
`emojiShortcuts` через Voice Record `/api/gt/settings`: `:custom-terminal:` и
другие шорткаты показываются как image/emoji, а если данных нет — fallback-icon.
Это важно для телефона: preview должен подтверждать тот же GT-документ, который
видит пользователь на Mac, но без прямого доступа к GT loopback/storage.

После выбора source/path папки внутри дерева раскрываются inline вниз, а не переводят sheet
в новый «экран папки». Это важно на телефоне: пользователь уже находится в нужной директории,
и каждый tap по подпапке должен разворачивать контекст, не сбрасывая текущий список и не
заставляя ходить назад-вперёд. Header при этом остаётся путём выбранного source; вложенность
показывается отступами и chevron-состоянием строк.

## Mobile model presets — быстрый switch двух связок

iOS хранит собственные mobile presets в App Group defaults, отдельно от desktop Voice Record
settings. Это намеренно: телефонный сценарий — быстрый выбор между двумя заранее выбранными
связками, а не синхронизация с desktop UI. Два слота: `Light` по умолчанию `lite + LOW`,
`Pro` по умолчанию `pro + HIGH`; в AI Chat settings каждая строка даёт выбрать model и
thinking level, а checkmark справа выбирает default slot для следующего открытия Voice
prompt picker.

Активный preset — это не отдельный третий источник истины для отправки. Switch копирует
выбранный slot в общие composer keys `voicechat.model` + `voicechat.think`; `/api/chat/send`
перед чтением request body вызывает ensure defaults и отправляет текущие `model`,
`thinkingLevel`, `bypass`. Поэтому то, что видно в composer/header picker, совпадает с тем,
что уходит на Mac. В Voice picker кнопка `Switch` текстовая, потому что это основной быстрый
переключатель перед отправкой диктовки; в AI Chat composer она compact icon-only слева от
model/think chips, чтобы не превращаться в третий широкий select. Модель в узком composer
показывается как family+version (`F3.5`, `L3.1`, `P3.1`, `F3`), а не длинными словами
Flash/Light/Pro: одна буква экономит ширину, число сохраняет различение поколений модели.
Prompt и GT в composer тоже icon-only: prompt — смысловая текстовая иконка, GT — маленький
letter-glyph `GT`. File-plus не используется для GT, потому что этот символ зарезервирован
под будущие обычные файловые вложения.

## Terminal model/effort/think — живой каталог + блокировка во время turn'а

Список моделей Terminal-mode не хардкодится на телефоне. iOS тянет `GET /api/agent-models`
(Codex — из live `codex debug models`, Claude — статический литерал desktop'а) и строит меню
из ответа, с фолбэком на встроенные литералы когда сервер старый/недоступен. Хардкод давал
симптом «у Codex показываются не все модели»: bundled-каталог это fallback-только, реальный
аккаунт через `/model` picker видит другой набор — авторитет у того же источника, что и
desktop. Эффорт Codex — per-model: берётся из `efforts` выбранной модели в каталоге, не общий
список. Для Claude в меню один Opus — строка `default` (= `/model default`, полный 1M контекст);
отдельный `opus` (`/model opus`, контекст-капнутый) убран, чтобы не было двух «опусов».

Model/effort/think заблокированы пока для вкладки идёт turn (`runningTabs`/`statusByTab=="busy"`,
тот же сигнал, что Send↔Stop). Живой `/model` switch посреди ответа небезопасен; блокировка
**без тоста** — disabled-вид это и есть affordance (зеркало desktop `custom-terminal/fact-codex.md::Модели и effort`).
Think — toggle, не Select: бинарное состояние живёт одной иконкой мозга сменой цвета
(серый off / акцент on) в long-press меню заголовка вкладки рядом с Rename, а не чипом с
текстом «Think ON/OFF» и стрелкой в composer'е (тот занимал ширину под бинарный флаг).

Что пробовали и почему не сработало (защита от регресса): после смены модели делали readback
`GET /api/sdk-tabs/:id/params` — для PTY-Claude он возвращает `bridgeMetadata.model`, который
**отстаёт** на ход после `/model`, поэтому чип дёргался opus→haiku→opus (юзер: «выбираю Opus,
между выбирается Haiku»). Решение: выбор применяется **оптимистично-локально** и держится,
readback после смены убран; SSE `bridge-update` со старой моделью игнорируется коротким окном
(`pendingModelByTab`, ~8с), пока мост не подтвердит выбранное. Лоадер param-чипа — центрированным
overlay'ем над скрытым текстом, ширина фиксирована (иначе смена модели меняла ширину и дёргала
ряд — desktop `fact-claude-control-bar.md::Busy-overlay вместо disabled`).

## Контекст-% в шапке — единый снапшот через /params, не отдельный канал

Процент израсходованного контекста показывается в статус-строке заголовка вкладки рядом с
runtime-статусом (`active · NN%`, цвет зелёный→жёлтый→оранжевый→красный по заполнению, число
крупнее статуса), а не плавающим чипом над лентой — это tab-level инфо. Слот всегда отрисован
для AI-вкладок: пока значения нет — тусклый `· –`, чтобы «данных ещё нет» отличалось от «фичи нет».

Число едет в том же `/params`-бандле, что model/effort (pull при открытии вкладки, `refreshParams`),
а не только живым SSE `bridge-update`. Симптом, который это лечит: модель появлялась сразу, а
процент — через ~30с (у contextPct был только live-push канал, без pull-on-open, и на idle-вкладке
он ждал следующего случайного `bridge-update`). Источник числа — родное значение источника
(StatusLine bridge у Claude, rollout `last_token_usage` у Codex), без пересчёта на телефоне;
desktop сидит его из SQLite (`tab.context_pct`) и в `/params`, и в списке вкладок, поэтому
значение есть на открытии до первого хода. SSE `bridge-update` после этого только патчит дельту.

## Прогресс/ошибка создания чата — на корне, не на скрытом табе

`chatBusy`-капсула и `chatError`-alert изначально висели на Voice-табе. Но успешный send
тут же переключает таб на AI Chat → Voice уходит со сцены → `.alert`, привязанный к нему,
**никогда не покажется**, и юзер думает «сработало». Поэтому статус создания чата
(`chatCreating`/`chatCreateError`) поднят на `TabRouter` и презентится в `RootTabView`
(над `TabView`) — переживает смену таба. Плюс `sendChat` гейтит двойной тап
(`guard !router.chatCreating`), иначе два быстрых тапа по промпту = два POST = два чата.

## Chat detail принимает готовую диктовку в composer

AI Chat и Voice — одно iOS-приложение, поэтому stop диктовки через Action Button / Control
Center toggle может быть продолжением уже открытого чата, а не отдельным copy-paste flow.
Активным потребителем текста считается **страница конкретного чата**, а не фокус внутри
`TextEditor`: на iOS фокус легко уходит из-за клавиатуры, toolbar, drawer или системного
overlay, но пользовательская модель остаётся «я сейчас в этом чате». Когда диктовка
завершается при открытом chat detail, готовый transcript вставляется в конец текущего
composer draft. Это именно append, чтобы не затереть уже набранный текст.

История не считается активным потребителем. Drawer, Recent и full All chats — поверхности
выбора разговора; если stop диктовки пришёл пока пользователь находится там, текст не должен
незаметно менять hidden draft какого-то чата. Это разделяет два намерения: «я сейчас
продолжаю этот разговор» vs «я выбираю разговор».

## Composer keyboard — overlay над transcript

В chat detail клавиатура и composer ведут себя как overlay над историей, а не как reflow
самого transcript. Когда пользователь фокусит input, dock с composer поднимается вместе с
клавиатурой поверх сообщений; список не получает keyboard-safe-area push и не должен
сдвигать историю вверх. Это намеренная модель мобильного чата: если пользователь читает
старое место в истории и тапает input, контекст чтения остаётся на месте, а ввод ложится
поверх. Кнопка hide keyboard и scroll-to-bottom живут в отдельной accessory row над composer
и появляются только когда клавиатура реально открыта; scroll-to-bottom меняет только позицию
списка, input при этом не закрывает.

Высота подъёма считается не из глобальной safe area и не из bounds SwiftUI-reader view, а
через пересечение keyboard end frame с `window.bounds` после `window.convert(...,
from: screen.coordinateSpace)`. Шрам: reader view может иметь другой frame, а iOS 26 safe-area
обновления приходят не в той фазе, из-за чего input оказывался под клавиатурой или ехал с
рассинхроном. `baseBottomInset` запоминается только пока keyboard hidden; `lift = keyboard
height - baseBottomInset`.

Keyboard-анимация не доверяется слепо стандартному SwiftUI fallback. На iOS 26 notifications
могут приходить с приватной curve `7`; для открытия composer использует front-loaded timing,
чтобы не отставать от клавиатуры. Закрытие штатных путей (`Send`, hide keyboard, offline)
стартует из app-owned `dismissKeyboard()` через proactive collapse (`0.160s`), потому что
финальные `keyboardWillChangeFrame`/`keyboardWillHide` на устройстве приходили уже после
начала системного hide, иногда с `duration=0`, и оставляли composer визуально зависшим
наверху. `keyboardWillHide` остаётся страховкой для системных путей закрытия, но не
источником timing для кнопки приложения. Логи `[Keyboard]` обязаны писать `frameEnd`,
`inWindow`, `safeBase`, `height`, `lift`, `curve`, выбранный `anim`, `willHide`,
`collapse reason=...` и `input tap`: это разделяет три класса багов — неверная геометрия,
неверная timing-кривая, или tap/focus перехвачен overlay/gesture. Reddit/GPT research не
дал готового публичного timing для iOS 26 private curve; числа калибруются по device logs.

## Скролл транскрипта: LazyVStack достаточно, порог эскалации известен

Архитектура списка выбрана по external research (июнь 2026, AI Studio + Perplexity +
Deep Research, плюс шрамы virtuoso→virtua из custom-terminal). Консенсус для тяжёлых
чатов (1000+ сообщений, токен-стриминг) — UICollectionView + кастомный layout в стиле
ChatLayout (ekazaev): кэш измеренных высот, компенсация дельты `contentOffset` в том же
runloop, когда ресайзится ячейка ВЫШЕ вьюпорта. Но наш чат в эту категорию не попадает:
ответы приходят целиком (без посимвольного стриминга), истории 50-200 сообщений — для
этого профиля SwiftUI `ScrollView` + `LazyVStack` достаточно, и эскалация не нужна.
Условия пересмотра зафиксированы: (а) появится настоящий токен-стриминг из runAgent,
(б) истории вырастут до тысяч сообщений, (в) появятся прыжки скролла при collapse
карточки выше вьюпорта. Тогда — менять контейнер (UIKit-обёртка), не наслаивать
SwiftUI-модификаторы (мета-урок миграции virtuoso→virtua: костыли поверх архитектурно
неподходящего инструмента не сходятся).

Follow-bottom — intent, не дистанция (шрам custom-terminal перенесён сюда с первого дня):
разоружает только жест юзера (`onScrollPhaseChange` → `.interacting`/`.tracking` — это
железный сигнал «палец на экране», программный скролл его не триггерит), рост контента
разоружить не может; re-arm у низа через `onScrollGeometryChange`. Пин — мгновенный
`proxy.scrollTo(anchor: .bottom)`, не анимированный (анимированные недолетают — тот же
шрам, что `align:'end'` в вебе).

**Прыжок скролла при отправке — keyboard-dismiss в том же runloop, что append
(FB20979569, iOS-26-only).** Симптом юзера: жму отправить → лента уезжает вверх почти на
целый экран (последние сообщения уходят за верх), приходится скроллить вниз руками, потом
новое появляется сверху. Магнитуда прыжка = высота клавиатуры, не высота строки — это и есть
отпечаток причины. Корень (подтверждён ресёрчем июнь 2026: ChatGPT-5.5 33 источника + Opus
4.8, оба сошлись): `send()` делал `dismissKeyboard()` (схлопывание bottom safe-area на экран)
**в том же transaction**, что optimistic-append, а тот синхронно дёргал `pin()` →
`scrollTo(.bottom)`; `.defaultScrollAnchor(.bottom)` при этом ре-анкорится на смену
contentSize. Над variable-height строками на iOS 26 это ровно FB20979569 — регрессия,
которой нет на iOS 18 (Apple DTS thread с repro: «jumps when in Dynamic size … only on iOS
26»). Наш стек совпадает с repro дословно: `ScrollView` + `LazyVStack` + `.defaultScrollAnchor(.bottom)`
+ `.scrollDismissesKeyboard(.interactively)` + строки переменной высоты.

Фикс (оба composer'а, Gemini и Terminal) — **развязать keyboard-dismiss и append**: армим
follow-bottom + append'им первыми, а `dismissKeyboard()` (и `resignFirstResponder` в Terminal)
откладываем на следующий runloop через `Task { await Task.yield(); … }` — пин ложится против
стабильной (клавиатура-вверх) геометрии, схлопывание клавиатуры идёт уже без совпадающего
`scrollTo`. Плюс `pin()` теперь пинит дважды: сразу + после `Task.yield()` — строка,
добавленная в этом же апдейте, ещё не измерена (DTS: «can't scroll to an item added in the
same update»), второй пин ложится против материализованной строки; `followBottom`
перечитывается после yield, чтобы юзера, схватившего скролл, не дёрнуло вниз. **НЕ** переехали
на `safeAreaInset` (ChatGPT/Opus оба советовали) — overlay-composer это документированная
keyboard-модель (`::Composer keyboard`), inset сломал бы её. Условие пересмотра — если
истории дорастут до тяжёлого токен-стриминга, durable-фикс по обоим ресёрчам — UICollectionView-обёртка
(тот же порог эскалации, что выше).

Markdown рендерится один раз на message.id (кэш `VCMarkdownCache`, ключ id+fontSize) —
не парсить в body при каждом скролле. Из ресёрча: MarkdownUI ушёл в maintenance mode
(преемник — Textual), поэтому свой лёгкий рендер (заголовки/списки/inline через
`AttributedString(markdown:)` + код-блоки вручную); полная подсветка синтаксиса —
Splash/Highlightr, когда понадобится.

Цветовые литералы в assistant text подсвечиваются прямо в `VCMarkdownCache`:
после `AttributedString(markdown:)` клиент сканирует обычный текст и inline code
на `#RGB/#RRGGBB`, `rgb(...)`, `rgba(...)` и ставит background/foreground на сам
токен. Fenced code blocks не проходят через этот pass и остаются буквальным
кодом. Это намеренная parity-реализация с desktop `claude-blocks`: нативный iOS
клиент не использует web-пакет, поэтому “цвет написан текстом, но его фон не
виден” нужно закрывать отдельно на SwiftUI-слое.

## Длинные сообщения: preview cap + Full sheet

Chat row никогда не должен layout'ить полный огромный `Text`/markdown/tool-output inline.
Пользовательский симптом: нажал `Show more`/раскрыл tool/thinking с очень длинным текстом —
всё приложение зависло, хотя загрузка истории и парсинг уже были off-main. Причина в другом
слое: SwiftUI layout одного гигантского `Text` остаётся main-thread работой. Поэтому лента
показывает capped preview: user bubble около 12K символов, assistant markdown около 16K,
thinking около 4K, tool detail около 20K, compact summary около 4K. Если текст длиннее,
ряд показывает `Full`, а не раскрывает полный payload на месте.

`Full` открывает отдельный sheet с loader'ом: сначала `ProgressView`, затем текст режется на
chunks в `Task.detached` (`vcChunkText`) и рендерится как `LazyVStack` маленьких `Text`.
Tool detail сначала строит строку в фоне с большим, но всё равно ограниченным budget
(до сотен тысяч символов), потом отдаёт её тому же full-sheet. Это прогрессивное раскрытие,
а не попытка "оптимизировать" один бесконечный `Text`. То же правило применено и к Terminal
history rows, потому что custom-terminal может прислать один `tool`/`compactSummary` на
десятки или сотни тысяч символов.

## История: Recent drawer и полный All chats — разные поверхности

Внутренний default AI Chat tab — новый draft, не history. Если пользователь ещё не выбирал
разговор в текущей жизни вкладки, открывается пустой чат; если разговор уже выбран, состояние
сохраняется и возвращается к нему. Это отличается от root default приложения: само приложение
по-прежнему cold-start'ит на Voice tab (`fact-voice-record.md::Tabs`).

Боковой drawer — быстрый слой последних чатов и вход в соседний Terminal mode, а не
полноценная страница истории. В нём есть заголовок `AI Chat` (title-only — settings-кнопка
переехала на top-left шестерёнку вкладки, см. `::Единые настройки приложения`),
строки `Chats` и `Terminal`, блок `Recent` и строка `All chats` **сразу после последних
recent-элементов**. `Terminal` не является recent-chat и не выбирает conversation id: это
переключатель центральной области в custom-terminal client. `All chats` не pinned над
`New Chat` и не резервирует место под него; она ведёт на отдельную полную страницу истории.
Текущий разговор сравнивается по id и остаётся выделенным в drawer, даже если пользователь
перешёл в чат и затем вернулся в историю.

`New Chat` — floating action поверх истории: белая кнопка с `+ New Chat` справа снизу,
поверх карточек, без участия в высоте content-flow. Если под неё добавлять bottom spacer
как под обычную строку, список заканчивается слишком рано и `All chats` визуально оказывается
«над кнопкой», хотя должен быть обычным последним row после recent-чатов. На full All chats
та же кнопка остаётся floating справа снизу; это действие создания, а не строка списка.

Full All chats — отдельная страница полного списка. Search здесь намеренно не toolbar
`.searchable`: продуктово он должен быть сразу раскрытым bottom-dock под floating
`New Chat`, а сама `New Chat` скрывается пока search focused или query non-empty. Кнопка
очистки/закрытия — отдельный круглый `x` той же высоты, с gap от поля, не маленький glyph
внутри инпута. Это исключение из правила «сначала системный search»: системный toolbar
search не даёт нужной композиции `New Chat` над search и отдельного clear-control. Settings
живут в едином экране (открывается top-left шестерёнкой, см. `::Единые настройки приложения`),
не в drawer; refresh-кнопки в chat header/drawer нет, потому что перезагрузка — не
постоянное действие чата, а recovery-контрол конкретного сбоя.

## History drawer gesture — контейнерный pan, не SwiftUI DragGesture

Результат external research по сломанному left/right drawer: это не обычная задача
`DragGesture` на SwiftUI-вью. Требование «история открывается слева, чат остаётся видимым
как 10% sliver» — custom interactive container transition. В regular width / iPad / Mac-like
layout история должна быть системным `NavigationSplitView`; compact iPhone использует
custom drawer только потому что продуктово нужен именно sliver, а не стандартный push/sheet.

Компактный drawer владеет одним root-level pan recognizer через `UIGestureRecognizerRepresentable`.
Не использовать hidden `UIViewRepresentable`, который в `DispatchQueue.main.async` цепляется к
`uiView.superview`: SwiftUI может reparent/replace host-view при navigation/search/keyboard/tab
changes, и recognizer начинает жить не на том слое. Состояние drawer хранится абсолютным
offset `0...drawerWidth` + phase (`closed/open/dragging/settling`), а не только delta от
`historyDragX`, чтобы interrupted spring, resize и смена `isOpen` mid-gesture не ломали базу.

Арбитраж со скроллом: до ясного горизонтального intent вертикальные `ScrollView` выигрывают;
после lock'а drawer pan выигрывает и временно блокирует scrolling до settle. Нельзя возвращать
`shouldRecognizeSimultaneouslyWith -> true` для всех recognizer'ов: это и даёт симптом «то
скролл, то drawer, то оба дергаются». Нужен кастомный `UIPanGestureRecognizer`, который может
prevent'ить `UIScrollView.panGestureRecognizer` после начала; `scrollDisabled` допустим только
на время активного drag/settling, не как постоянная структура. Intent-lock строится по
translation hysteresis (примерно 8-10pt) с velocity как fast-path, а не по velocity-only
`shouldBegin` — медленный уверенный свайп иначе не стартует.

Closed/open states имеют разные правила. Closed: rightward pan открывает только когда chat
на root и navigation stack не может pop; touch, начатый прямо из `UITextField`/`UITextView`
или `UIControl`, не принимает drawer recognizer, чтобы не ломать редактирование текста и
кнопки. Но если пользователь открывает историю через hamburger или принятый rightward pan по
области чата, сначала явно сбрасывается focus (`resignFirstResponder`) — iPhone-клавиатура
не должна оставаться раскрытой под drawer. Open: leftward pan закрывает из drawer и из видимого chat sliver, tap по sliver
закрывает. После начала контейнерного pan `cancelsTouchesInView = true`: row taps, long-press,
buttons и text fields не должны продолжать получать touch как будто modal container drag не
начался. Drawer width — `min(max(280, width * 0.90), width - 44)`, чтобы даже на узком экране
оставался usable sliver.

Если когда-нибудь возвращать row-level swipe actions в истории, их нельзя просто совместить
с full-width horizontal drawer: это два горизонтальных жеста на одной поверхности. Либо drawer
остаётся контейнерным и row swipe удаляется, либо вводятся явные exclusion zones/режимы.

## Единые настройки приложения: full-screen, segmented + swipe, память секции

Настройки трёх вкладок (AI Chat · Voice · Habits) — **один** экран `AppSettingsSheet`,
презентуемый `fullScreenCover` на корне (`RootTabView`), поверх всего шелла, а не три
отдельных пер-таб sheet'а. Раньше у каждой вкладки был свой sheet со своим NavigationStack +
Done; теперь три тела вынесены в `*SettingsBody` (без своего стека/title/Done) и
переиспользуются внутри одного сегмент-контейнера, а старые `*SettingsSheet`-структуры
оставлены тонкими врапперами для standalone/preview. Точка входа единая: top-left шестерёнка
(`gearshape.fill`) на **всех** поверхностях — Voice, Habits, AI Chat (chat detail + All chats)
и Terminal (projects / project tabs / chat). Все они зовут `router.openSettings()`.

Внутри экрана сверху segmented-контрол `[AI Chat | Voice | Habits]` + горизонтальный
paging-`ScrollView` (тот же `scrollTargetBehavior(.paging)` + `scrollPosition(id:)` +
`containerRelativeFrame`, что у корневого пейджера) — секции листаются свайпом, segmented и
свайп синхронизированы в обе стороны. Конфликта со свайпом корневых вкладок / history drawer
нет, потому что экран живёт в `fullScreenCover` поверх шелла — там нет конкурирующего
горизонтального pan-recognizer'а (контракт корневого свайпа — `::Свайп root-вкладок`).

В AI Chat top-left перестал открывать drawer — это теперь шестерёнка. **Drawer открывается
только свайпом** слева-направо (контейнерный pan, `::History drawer gesture`); кнопочного
открытия больше нет. Шестерёнка из шапки drawer убрана.

Память секции живёт на `TabRouter`: `settingsSection` пере-засевается в `selected` на КАЖДОЙ
смене корневой вкладки (`selected.didSet`), а внутри настроек свободно меняется segment'ом /
свайпом и **persist'ит между открытиями, пока юзер на той же вкладке**. Пользовательская
модель: открыл из AI Chat → секция AI Chat; переключил на Habits, закрыл, снова открыл из AI
Chat → Habits (выбор сохранился); ушёл на вкладку Habits и вернулся в AI Chat → снова AI Chat
(смена вкладки пере-установила дефолт). Принцип — `methodology/переносимый-дизайн.md::Контекст-засеянный дефолт`.

## iOS 26 chrome: системный search/glass вместо ручного стекла

Для navigation/search chrome сначала использовать реальные SwiftUI контейнеры:
`.toolbar`, `ToolbarItem`, `.searchable`, `.searchToolbarBehavior(.minimize)`. На iOS 26 они
получают Liquid Glass, grouping, scroll-edge legibility, clear/cancel search lifecycle и
keyboard behavior от системы. Ручная капсула с blur/stroke может быть похожа на скриншоте,
но не получает системное поведение и часто приносит лишний parent background — симптом из
этой итерации: search оказался внутри тёмного блока, который тянулся до tab bar, а кнопки
settings/refresh выглядели как кастомные React-элементы без нативного glass.

Обратная сторона той же медали: КАСТОМНЫЙ контрол внутри системного toolbar получает
системный glass принудительно. На iOS 26 toolbar оборачивает каждый `ToolbarItem` в
Liquid Glass-кружок; для контрола со своим визуалом (двухстрочный By-pass pill: тумблер +
подпись) это двойной хром — юзер: *«отображается какой-то стандартный кружочек iOS поверх,
убери его»*. Точечный opt-out: `.sharedBackgroundVisibility(.hidden)` на конкретном
ToolbarItem (iOS 26 API, под `#available`), не отказ от toolbar целиком — соседние
стандартные иконки-кнопки свои кружки сохраняют.

Если control живёт вне системного toolbar, как settings в custom drawer header, использовать
платформенный style (`.buttonStyle(.glass)` на iOS 26, `.bordered` fallback), а не ручной
круг с материалом. Header/search/composer не должны рисовать фон, отличающийся от page/root
background: иначе у Dynamic Island/top edge и над tab bar появляются чёрные или слишком
светлые полосы. Для AI Chat root, tab bar и page background держатся одним тёмным цветом.

Для custom bottom search dock на iOS 26 это правило не отменяется: раз control живёт вне
toolbar, поверхность всё равно строится через `GlassEffectContainer` + `glassEffect(...,
in: .capsule/.circle)` или эквивалентный системный glass API, а не через
`Color.white.opacity(...)`. Opacity-fill выглядит как серый прозрачный блок и не даёт
настоящего Liquid Glass перелива. Dock также обязан владеть hit-test зоной: визуально
лежащая сверху glass-кнопка `x` без собственного `contentShape`/tap consumer может пропустить
тап в chat row под ней — пользователь видит попадание в крестик, но открывается чат позади.

Мелкие controls в composer тоже не занимают место без причины. Model chip в выбранном
состоянии компактный: `Flash-Lite` показывается как `Lite`, а полное имя остаётся в dropdown.
Кнопка скрытия клавиатуры появляется только когда клавиатура реально открыта, и стоит над
composer справа; внутри input row она создавала пустую ширину и визуально ломала поле ввода.

## By-pass на iOS живой во время стрима

Toolbar-переключатель By-pass — глобальный default для draft, но существующий чат зеркалит
серверный per-chat state. На загрузке `GET /api/chats/:id` приносит `bypass`; при смене
переключателя iOS шлёт `/api/chat/bypass {chatId,bypass}`. Сервер перечитывает состояние
на каждом tool-call, поэтому включение By-pass во время уже ожидающего confirm сразу
разрешает висящие карточки и влияет на следующий `edit_file`/`write_file`/`bash`.
Локально клиент tombstone'ит закрытые callId, чтобы stale rehydrate не воскресил карточку.

Пользовательский симптом, который эта модель закрывает: *«Bypass не работает во время
стриминга»*. Не возвращаться к схеме «bypass только параметр `/api/chat/send`» — это снова
захватит значение в начале turn и сломает mid-stream toggle.

## Stop и thinking: partial answer сохраняется

`VCMessage` декодирует `thinking`, `toolCalls`, `stopped`. Если Stop случился до первого
assistant artifact, сервер шлёт `cancelled`, а клиент возвращает исходный текст в composer.
Если успел прийти хотя бы thinking или tool-call, это уже не rollback: сервер сохраняет
assistant-message со `stopped:true`, iOS показывает сворачиваемый Thinking-блок, tool cards
и метку «остановлено». Это тот же контракт, что у desktop overlay; цель — не стирать
частичный ответ нейронки, если она уже успела вызвать MCP/bash или выдать thinking.

Thinking рендерится отдельной карточкой перед tool cards, а не как markdown content. Иначе
stopped-after-artifacts turn выглядел бы как пустое сообщение с исчезнувшим прогрессом.

## Кнопка отправки: arming авто-отправки (общий `ComposerSendButton`)

Круглая кнопка отправки в обоих composer'ах (Gemini-чат и Terminal) — общий
`ComposerSendButton` (в `VoiceChat.swift`), маленький стейт-машина: есть draft → обычная
отправка; armed → отмена арминга (НИКОГДА не отправляет, явный guard); пустой инпут → тап
no-op. **Арминг только по long-press** (вибрация + `.popover` «Активировать авто-отправку»
над кнопкой), не по пустому тапу — юзер прямо убрал арминг-по-пустому-тапу как
случайно-срабатывающий. Armed-состояние = фиолетовый indeterminate `ProgressView`; пока
armed, пришедшая из Toggle Voice Record диктовка не просто вставляется в инпут, а
**авто-отправляется**.

Почему именно так (невидимый контекст, мотивация — внешний софт диктовки): юзер настроил
боковую кнопку на Toggle Voice Record, заранее жмёт send-кнопку чтобы «вооружить» инпут, и
голосовое уходит само по завершению диктовки. Если текст уже впечатан — пустой тап отправил
бы его, поэтому арминг повешен на long-press, который работает в любом состоянии инпута.

Три неочевидных решения. (1) Жест — раздельные `.onTapGesture` + `.onLongPressGesture` на
plain-фигуре (не `Button`, не `.simultaneousGesture`): duration-gate делает их
взаимоисключающими, избегая iOS-26 trap «срабатывают оба сразу». `suppressTap` зеркалит
проверенный паттерн `VoiceChatGTFileRow`. (2) **Дисарм синхронно ДО** `send()` в
`consumePendingDictationInsert` — иначе вторая вставка во время сетевого round-trip
ре-триггерит отправку (защита от двойной отправки); seq-guard стора делает consume
идемпотентным к пересборке вью. (3) `.contentShape(Circle())` на всю кнопку — прозрачные
зазоры спиннера не должны создавать мёртвых зон для тапа-отмены. Арминг сбрасывается при
уходе с composer-поверхности и в offline. Анимация смены стрелка↔лоадер — 0.15с (юзер просил
«прям быстро»). Выбор раздельных жестов вместо `ExclusiveGesture`/`.simultaneousGesture`
подтверждён ресёрчем (ChatGPT-5.5 35 источников + Claude Opus, июнь 2026). Эталон жеста под
вес действия — `methodology/переносимый-дизайн.md::Жест под вес действия`.

## Свайп root-вкладок и почему книжного слайда нет

Перелистывание между AI Chat · Voice · Habits — `TabPagingSwipe` (UIKit
`UIPanGestureRecognizer` через `UIGestureRecognizerRepresentable`, в `TabRouter.swift`),
коммитит `router.page(delta:)` на отпускание. Voice (середина) листается в обе стороны;
Habits (крайняя) — только вправо→Voice и **выключен во время reorder/драга строки** (тот
режим владеет вертикальным драгом); AI Chat (крайняя) — только влево→Voice, и **выключен
пока drawer открыт/тащится, идёт ввод текста, или Terminal-mode владеет своим back-swipe**
(rightward-when-closed принадлежит history drawer, leftward свободен жесту). UIKit-распознаватель,
а не SwiftUI `DragGesture` — на iOS 18/26 SwiftUI-жест не сосуществует детерминированно с
приватным pan'ом `UIScrollView`; зеркалит `HistoryDrawerPanRecognizer` (intent-lock по
горизонтали, declines тачи в text field / control / горизонтальном scroller,
`cancelsTouchesInView`, левый край ~28pt отдан системному back-swipe).

**Graveyard — книжный слайд невозможен с нативным таб-баром.** Юзер хотел чтобы свайп
выезжал «как чтение книги», а не fade. Ресёрч (ChatGPT-5.5 35 источников + Claude Opus, июнь
2026, с пометкой 2026/iOS 26) и доки прямо: системный bar-style `TabView` **by-design**
делает только cross-dissolve, `.transition(.slide)`/`.animation` на selection — no-op; нет
iOS 18/26 API для интерактивного слайда между обычными таб-бар вкладками. Книжный слайд
достижим **только** кастомным horizontal paging-ScrollView (`.scrollTargetBehavior(.paging)`
+ `.scrollPosition` + `.containerRelativeFrame`) + **кастомным** таб-баром. Прототип сделали
и **откатили**: кастомный плоский таб-бар (а) обрезал нижний ряд Voice (микрофон + капсюль),
потому что не резервирует safe-area как системный, (б) `Color.white.opacity(...)`-fill
выглядел серым прозрачным блоком без Liquid Glass перелива (тот же шрам что в `::iOS 26
chrome`). Юзер: «некрасиво вообще нихуя», и явный fallback «если нельзя нормальный glass как
было — вернуть нативные три кнопки». Вернули нативный `TabView`: настоящий glass, правильная
safe-area, ничего не обрезается; свайп остался, но переключение снова fade. Не переизобретать
кастомный pager ради слайда — цена (потеря системного chrome) перевешивает. Принцип —
`methodology/переносимый-дизайн.md::Нативный компонент vs кастом`.

## Rename чатов, терминальных вкладок и проектов

Long-press на строке истории чатов и на title в detail открывает Rename sheet. Сохранение
идёт через `PATCH /api/chats/:id {title}` на Mac, затем `loadConversation`/`refreshChats`.
Пустой title = вернуться к auto-derived названию. Это важно: title живёт в общем
`conversations.json`, должен синхронизироваться с desktop overlay и другим клиентом, а не
оставаться локальным iOS-state.

Тот же long-press-стандарт распространён на Terminal mode: нативный `.contextMenu` (Rename +
Copy) на трёх поверхностях — шапка чата вкладки, строка вкладки (страница вкладок проекта),
строка проекта (страница проектов). Rename открывает общий `CTRenameSheet` (зеркало
Gemini-шита `VoiceChatTitleEditorSheet`). Бэкенд — custom-terminal: **вкладки** через уже
существовавший `POST /api/sdk-tabs/:id/rename` (bridge `renameTab`, ставит
`nameSetManually=true` чтобы команда не затёрла имя — `custom-terminal/fix-tab-naming-race.md`);
**проекты** через добавленный в эту сессию `POST /api/projects/:id/rename` (bridge
`renameProject` → `updateProject{name}` → персист `project:save-metadata` в SQLite).
`TerminalControlStore` применяет переименование оптимистично (мутирует `CTTabInfo.name` /
`CTProject.name` во всех @Published-коллекциях) и откатывает reload'ом при ошибке POST.
Long-press = `.contextMenu` сознательно, а не кастомный жест — см.
`CLAUDE.md::Стандарт long-press` и `methodology/переносимый-дизайн.md::Нативный компонент vs кастом`.

## Связанное

- `voice-record/docs/knowledge/fact-mobile-bridge.md` — сервер, SSE, REST, By-pass,
  thinking/stop protocol.
- `fact-voice-record.md::Tabs` — порядок root-вкладок AI Chat · Voice · Habits.
- `fact-remote-tab.md` — legacy WKWebView/custom-terminal wrapper и shared RemoteConfig,
  откуда Terminal mode берёт host/token.
- `custom-terminal/docs/knowledge/fact-mobile-web.md` и `fact-mobile-claude-pty.md` —
  REST/SSE контракт Terminal mode, `/agent-tabs`, `/interrupt`, `/draft`,
  status marker/project icon поля.
- `fix-ios-stability.md::iOS 26 keyboard notifications` — почему composer не должен
  полагаться на safe-area push и дефолтную SwiftUI-анимацию keyboard events.
- `fix-ios-stability.md::Terminal navigation jank` — почему Terminal-переходы измеряются
  watchdog + CADisplayLink phase logs, и какие подходы уже отвергнуты.
- `methodology/сценарии-использования.md::Chat из Voice-экрана` — путь юзера.
- `methodology/переносимый-дизайн.md::Нативный компонент vs кастом` — почему search/toolbar
  сначала должны жить в системных контейнерах и почему drawer-pan уходит на UIKit-recognizer
  слой.
- `methodology/переносимый-дизайн.md::Длинный контент раскрывается отдельной поверхностью`
  — почему большие chat/tool/thinking тексты не раскрываются inline.
- `methodology/диагностика-apple.md::Фриз требует наблюдателя вне замёрзшего цикла` —
  почему nearby logs без внешнего наблюдателя не доказывают причину фриза.
