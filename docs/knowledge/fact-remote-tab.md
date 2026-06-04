# Fact: Remote tab (встроенный браузер к custom-terminal mobile-web)

Третья подсистема приложения: вкладка **Remote** (между Voice и Habits) рендерит mobile-web SPA из проекта `custom-terminal` внутри `WKWebView`. Это полноэкранный сайт без хрома Safari — выглядит как нативный экран, внутри живой web. Бэкенд и протокол — на стороне custom-terminal (`custom-terminal/docs/knowledge/fact-remote-access.md`, `fact-mobile-web.md`); здесь — только iOS-обёртка.

Код: `HabitTracker/Remote/` — `RemoteConfig.swift`, `RemoteWebView.swift`, `RemoteTabView.swift`.

## Почему WKWebView, а не SFSafariViewController

`SFSafariViewController` тащит адресную строку и тулбар Safari, открывается модально — для постоянной вкладки не годится. `WKWebView` встраивается как обычный `UIView`, полный контроль над навбаром и failure-состоянием. Поэтому offline-overlay, navbar-кнопки и progress-линию рисуем сами.

## Auth: токен нативно, НЕ логин/пароль

mobile-web не имеет форм логина — авторизация это **bearer-токен** (`crypto.randomBytes(24)` hex, 49 байт на маке в `~/.noted-terminal/web-token.txt`). Токен **стабильный, не ротируется**. Кладётся в `Secrets.swift::remoteWebToken` (как `sonioxAPIKey`, файл в `.gitignore`).

Поток: `RemoteConfig.tokenizedURL` добавляет `?token=...` к URL → mobile-web `bootstrapToken` (`api.ts`) при первой загрузке снимает токен из URL, кладёт в localStorage, чистит адресную строку через `history.replaceState`. Дальше токен живёт в localStorage веб-вью.

**Ключевое следствие для «очистить данные».** Раз токен мы держим нативно и подставляем на каждой свежей загрузке — любая чистка безопасна: после стирания localStorage следующая загрузка через `tokenizedURL` снова залогинит. Поэтому «Сбросить сайт (всё)» не выкидывает юзера навсегда.

## Persistent data store

`WKWebViewConfiguration.websiteDataStore = .default()` — **персистентный** контейнер: куки + localStorage + кэш переживают перезапуск процесса и телефона. Это **отдельный от Safari** жбан (никакой связки с системными куками). Веб-вью создаётся один раз на жизнь вкладки (`RemoteWebController` — `@StateObject`), страница остаётся тёплой.

Две операции чистки (`RemoteWebController`):
- `clearCookiesAndCache` — стирает `Cookies + DiskCache + MemoryCache + FetchCache`, **сохраняет localStorage** → вход остаётся, юзер залогинен.
- `resetAllData` — `WKWebsiteDataStore.allWebsiteDataTypes()` (включая localStorage, IndexedDB, service workers) → токен тоже стёрт, но сразу вызывается reload с `tokenizedURL` → чистая свежая сессия.

## Источник Prod/Dev (toggle в настройках)

`RemoteConfig` (хранение в App-Group suite, ключи `remote.useDev` / `remote.devHost`):
- **Prod** — фиксированный публичный HTTPS-домен (доступен из любой сети). Reverse SSH tunnel → VPS nginx → Mac Electron :7878.
- **Dev** — редактируемый `ip:port` (default — LAN-адрес dev-сервера, порт `NOTED_WEB_PORT`). Только LAN, plain HTTP. Bare `ip:port` → дефолтит на `http://`.

**Сам домен и dev-IP — в `Secrets.swift` (gitignored), не в коде.** `RemoteConfig.prodURL` / `defaultDevHost` читают `Secrets.remoteProdURL` / `remoteDefaultDevHost`. В committed-исходниках публичного адреса нет — placeholder поля и footer настроек тоже без литералов.

Смена toggle или коммит dev-адреса (`onSubmit` / кнопка «Применить») → `loadCurrent()` с новым URL. **Тонкость со синхронностью этого чтения — см. ниже «State propagation»**: наивная версия читала источник из `@AppStorage` и грузила старый адрес.

## State propagation: `@AppStorage` отстаёт на runloop

Источник (Prod/Dev) и dev-адрес живут в App-Group `UserDefaults` и читаются в трёх местах: лист настроек (пишет), загрузчик страницы (`loadCurrent`), навбар (подпись + цвет точки). Завязать все три на `@AppStorage`-обёртку нельзя — `@AppStorage` обновляет своё значение через KVO на **следующем** runloop, а не синхронно с записью. Отсюда два бага, оба по одному корню:

1. **Переключатель Dev не применялся.** Симптом юзера: *«нажимаю Dev — галка с Prod убирается, но грузится всё тот же прод-адрес»*. Picker писал новое значение в стор, тут же дёргался `onChange → loadCurrent()`, но соседний `@AppStorage`-проп в том же цикле ещё отдавал **старое** `useDev=false` → собирался прод-URL. Reload не помогал — он перезагружал текущую (прод) страницу, а не перечитывал источник.
2. **Подпись в навбаре отставала.** Симптом: *«адрес слева вверху меняется только если выйти и зайти на вкладку Remote»*. Навбар читал `useDev`/`devHost` из `@AppStorage`; пока лист настроек поверх — SwiftUI откладывал перерисовку навбара под ним до повторного показа вкладки.

Решение: **загрузчик читает источник напрямую из стора** (`RemoteConfig.useDev`/`.devHost` — live, отражает запись мгновенно), а навбар и offline-экран читают **не** `@AppStorage`, а `@State`-снимок (`activeIsDev`/`activeHost`), который ставится в `loadCurrent()` в момент загрузки. Тогда подпись и URL всегда из одного источника и меняются в один такт.

Что пробовали и почему не сработало: исходно все три точки читали sibling-`@AppStorage` — самый прямой SwiftUI-способ. Он и дал stale-read внутри цикла записи. `@AppStorage` хорош когда значение только **отображается** и допустима задержка в кадр; для «прочитать ровно то, что секунду назад записал другой контрол» он не годится — нужен прямой read стора, а зависящий от него UI гнать через явный `@State`, выставляемый в момент действия.

## Dev-режим: два iOS-подводных камня

1. **ATS блокирует http://** на не-localhost адреса. Лечение: `NSAppTransportSecurity → NSAllowsLocalNetworking = true` в main app `Info.plist`. Этого хватает для приватных диапазонов LAN; полный `NSAllowsArbitraryLoads` не нужен.
2. **Local Network privacy prompt.** Первое обращение к Mac по LAN → системный запрос «разрешить доступ к локальной сети». Без `NSLocalNetworkUsageDescription` в `Info.plist` запрос не покажется и коннект молча упадёт. Prod (публичный HTTPS) обоих камней не имеет.

## Offline / failure-обработка (без чёрного экрана)

`WKWebView` при недоступном сервере показывает пустую белую/чёрную страницу. Вместо этого `RemoteWebController` ловит `didFailProvisionalNavigation` / `didFail` → флаг `didFail` → `RemoteTabView` рисует нативный `RemoteOfflineView` (иконка `wifi.slash`, host, сообщение, для dev — подсказка про «Mac в той же сети», кнопка «Перезагрузить»).

- `NSURLErrorCancelled (-999)` игнорируется — это нормальная отмена при быстрых reload/redirect, не реальный сбой.
- Канвас веб-вью тёмный (`white:0.04`, `isOpaque=false`) — reload/переход не мигают белым.
- Reachability выводится **из исхода навигации**, не из отдельного reachability API — единственное что важно «загрузилась ли страница».

## Кнопки в навбаре, не в настройках

Per требование юзера, reload (`arrow.clockwise`) и шестерёнка (`gearshape`) живут **в навбаре** (toolbar trailing), плюс в principal — точка статуса (зелёная prod / оранжевая dev / красная offline) + host. Шестерёнка открывает лист с toggle Prod/Dev, редактируемым dev-адресом и тремя действиями данных (обновить / очистить куки / сбросить всё).

## onAppear-guard: не перезагружать при каждом возврате

`TabView` шлёт `.onAppear` на **каждое** переключение обратно на вкладку. Без guard'а страница перезагружалась бы (терялся scroll + composer) при каждом заходе. Флаг `didInitialLoad` — initial load один раз, дальнейшие загрузки только явные (navbar reload, смена источника/адреса, reset данных).

## Xcode project: main target — classic groups

Main `HabitTracker` target **не** использует `PBXFileSystemSynchronizedRootGroup` (synchronized только у `HabitWidget.`). Поэтому новые `.swift` в main target надо регистрировать в `project.pbxproj` вручную: PBXBuildFile + PBXFileReference + PBXGroup children + Sources build phase. Файлы `Remote/` добавлены под группой `A1B2C3DB20 /* Remote */`. WebKit автолинкуется через `import WebKit` — отдельная запись в Frameworks phase не нужна.

## Связанное

- `custom-terminal/docs/knowledge/fact-remote-access.md` — VPS, autossh tunnel, nginx, offline-page на стороне сервера.
- `custom-terminal/docs/knowledge/fact-mobile-web.md` — endpoint map, токен, SSE-транспорт, история.
- `fact-voice-record.md::Tabs` — порядок вкладок Voice · Remote · Habits.
