# Live Activity (Dynamic Island)

Расширение Voice Record subsystem'ы. ActivityKit + WidgetKit. Lock Screen banner + Dynamic Island compact/minimal/expanded + Notification Center.

## NSSupportsLiveActivities обязателен в ОБОИХ Info.plist

Apple docs: ключ нужен в **app target** И **widget extension target**. Без него в widget extension iOS принимает `Activity.request()` (возвращает валидный Activity ID), но **ничего не рендерит** — ни в Island, ни в NC, ни на Lock Screen. Symptom: тихий fail без exception.

Дополнительно добавлен `NSSupportsLiveActivitiesFrequentUpdates=true` в обоих — без него iOS throttle'ит updates до 1/мин в background, и Soniox preview-text stream не успевает отображаться.

## relevanceScore default = 0, нужно явно задавать на КАЖДЫЙ update

`ActivityContent(state:staleDate:relevanceScore:)` — `relevanceScore` имеет default `0.0`. Если ты передал `1.0` при `Activity.request()`, но при первом же `update()` создал `ActivityContent(state:, staleDate: nil)` без relevanceScore — score сбрасывается в 0.

**Что это значит:** при многих одновременных Live Activities (наш + Яндекс.Доставка / Uber / Apple Phone) iOS даёт compact Dynamic Island slot **только activity с наивысшим score**. С default 0 — мы проигрываем кому угодно с >0.

**Решение:** на КАЖДОЕ emission (start/update/end) передавать `relevanceScore: 100`. Apple HIG рекомендует 100 как safe-priority для "должно перебить всё". Тип Double без верхнего cap'а, но 100 достаточно.

`RecordingActivityManager.pinnedRelevance = 100.0` + helper `freshStaleDate()` (now + 8h) применяется ко всем `ActivityContent` инициализациям.

## staleDate=nil — НЕ виновник, но передаём now+8h на всякий случай

Gemini Pro (см. сессию research): `nil staleDate` означает "без срока годности до hard 8h system limit", iOS НЕ убирает Activity из Island за это. **Predicate, который я подозревал как причину, оказался ложным.** Тем не менее в коде передаём `Date() + 8h` — это idempotent fallback, не вредит.

## Dynamic Island pop-out: ТОЛЬКО через AlertConfiguration

`Activity.request()` сам по себе **НЕ играет pop-out animation** (большой банер выезжает сверху на 2-3 сек и сворачивается в Island). Это by-design Apple — чтобы каждое создание Activity не спамило банером.

**Pop-out играется только когда `Activity.update(content:alertConfiguration:)` получает non-nil `AlertConfiguration`.** Это explicit opt-in от разработчика "эта transition важная, выезжай". Phone / Maps / Uber делают именно так на старте звонка/маршрута.

```swift
let alert = AlertConfiguration(title: "Voice Record",
                               body: "Запись началась",
                               sound: .named(""))   // silent — empty name suppresses chime
await act.update(ActivityContent(state:..., staleDate:..., relevanceScore: 100),
                 alertConfiguration: alert)
```

`sound: nil` API не допускает; `.named("")` — silent pop-out (выезд без звука уведомления).

## AlertConfiguration suppressed когда app в foreground

By-design Apple: notification-style banners (включая Live Activity pop-out) подавляются для активного приложения. Эта же политика как с обычными `UNNotification` — Apple считает банер избыточным когда юзер уже смотрит на app.

**Что пробовали для обхода:**
- `Activity.update` с alertConfiguration из main app после `setPhase(.recording)` — app foreground, suppress.
- `Activity.update` сразу после `Activity.request` в Kickoff — request успевает до foreground, но subsequent update идёт уже когда app поднялся → suppress.

**Workaround:** `Activity.request` + immediate alerted `update` **из widget extension process** (см. ниже). Extension considered background → Apple играет pop-out. После этого app поднимается и `RecordingActivityManager.start()` **adopt'ит** существующую Activity.

## Kickoff from widget extension + adopt pattern

`LiveActivityKickoff.requestIfNeeded()` живёт в `HabitWidget./` папке (виден обоим targets через FS-sync + explicit ref в main app). Вызывается **прямо в `Intent.perform()`** до `postPendingAction`. Идempotent: при existing activity — no-op.

```swift
// В Toggle/Start/Shortcut intent.perform():
if action == "start" {
    await MainActor.run { _ = LiveActivityKickoff.requestIfNeeded() }
}
postPendingAction(action)
```

`RecordingActivityManager.start()` adopt-логика: при `Activity<RecordingAttributes>.activities.first` — reuse его, не создавать новую. Иначе вторая `request` отменила бы первую и pop-out пропал.

```swift
if let pre = Activity<RecordingAttributes>.activities.first {
    current = pre
    // … подписаться на activityStateUpdates для diagnostic logs
    return pre
}
// only reach here on manual app-launch flow (no intent involved)
```

## Compact/minimal views — статичные SF Symbols, никаких animations

Compact slot (~24pt wide рядом с Face ID) и minimal (точка) рендерятся **out-of-process** SpringBoard'ом. Когда SwiftUI closure в этих slots faulть (repeating animation на `.onAppear`, indeterminate `ProgressView`, force-unwrap nil, missing asset) — SpringBoard self-defending дропает **весь** Island view, оставляя только lockScreen path (NC).

**Симптом:** Activity видна в NC и Lock Screen, но в Dynamic Island compact slot — ничего, или пустое место рядом с Face ID.

**Решение:** в compact/minimal — только `Image(systemName:)` со статичным `.foregroundStyle`. Pulse-анимации и spinner'ы оставлены **только** в lockScreen view (in-process, безопасно).

В compact trailing: `Text(timerInterval:)` системой ticking — безопасно (это primitive). Был `ProgressView()` на `.starting/.stopping` — заменил на `Text("•••")`. В minimal: timer тоже добавлен в `.recording` фазе — когда iOS форсит multi-LA в minimal-mode, юзер видит секунды:минуты.

## Активный mic перебивает наш Activity в Island compact

System policy: при активной записи микрофона iOS показывает **свой orange-dot indicator** в Dynamic Island compact и **демотит** все non-system activities в minimal. Это by-design (privacy) — наш Activity при recording phase будет в minimal slot слева/справа, не в compact. Перебить нельзя.

**Что это значит для UI:** при `.recording` наш minimal-view должен быть информативным (timer + mic). Compact UX доступен только в `.starting` / `.stopping` (когда mic ещё не активен).

## Lifecycle: end + immediate re-request на каждый toggle (диктовка-соло)

Для **диктовки в одиночку**: каждый stop → `dictationEnd(immediate: true)` → Activity полностью dismiss'ится. Следующий start → новый `request()` из intent perform → новая pop-out. Без полного end re-request не сыграл бы animation (Apple ровно одну на жизненный цикл Activity).

**Исключение — параллель с long.** Если на момент `dictationEnd` ещё идёт long-запись, Activity НЕ dismiss'ится — диктовочный слот откатывается в `.idle`, Activity живёт дальше под long-chrome (см. «Параллель: одна Activity» выше). Симметрично `longEnd` при живой диктовке лишь чистит long-поля. Реальный dismiss — только когда оба слота ушли в idle.

## `.ended` pop-out перед dismiss даёт banner без persistent Activity

Раньше для зелёного «Готово» banner'а на стопе мы держали persistent `.idle` Activity и rewind'или её в `.ended` через alerted update. Этот workaround снят (см. секцию ниже). Сейчас тот же визуальный эффект достигается без всякого persistent state: в `RecordingActivityManager.end()` перед реальным `act.end()` шлём alerted `update()` с phase=`.ended`, body=«Готово — текст скопирован», sound=`.named("")` (silent). Ждём 1.5s inline (`Task.sleep`, не fire-and-forget — perform() awaits весь chain), затем `act.end(dismissalPolicy: .immediate)`. Юзер видит зелёный banner / Lock Screen confirmation, потом чистое исчезновение.

Inline sleep важен: fire-and-forget Task для второго update race'ится с iOS suspend'ом процесса сразу после возврата из intent.perform() — banner успеет показаться, но dismiss не зафиксируется → zombie Activity.

## activityState guard перед mutate

ActivityKit бросает exception (и крашит host process) если `update()` или `end()` вызвать на Activity которая уже `.dismissed` / `.stale`. Это race с system-инициированным dismissal: например `alertConfiguration` на `setPhase(.stopping)` может триггернуть stale→dismissed transition быстрее чем наш await-цепочка `end()` дойдёт до своих update'ов.

Защита во всех методах что мутируют Activity (`setPhase`, `setStreaming`, `setPreviewText`, `end`): первой строкой проверять `act.activityState != .active` → log + return. Шрам: см. `fix-dynamic-island.md::Шрам 7`.

## Persistent `.idle` mode [deprecated — workaround снят]

**Был зачем.** Думали что `Activity.request()` запрещён из background всегда. Workaround — держать Activity живой в `.idle` фазе, чтобы Shortcut Toggle мог `update()` существующую вместо `request()` новой.

**Почему снят.** На iOS 17+ Apple явно документировал исключение: *«you can't call Activity.request() while your app is in the background, **unless** you adopt App Intents and start the Live Activity using a LiveActivityIntent»* (ActivityKit docs). Наш `ToggleVoiceRecordingShortcutIntent` уже conform'ит `LiveActivityIntent` → его `perform()` foreground-equivalent для Activity.request, без всякого persistent state. Подтверждено живым тестом: stop → start через Action Button работает корректно создавая новую Activity каждый раз.

**Что осталось от workaround'а.** Ничего в runtime — `keepLiveActivityAlive` всегда `false`, `startIdle()` не вызывается, Pin-кнопка убрана из UI. Когда нужен .ended pop-out banner — делаем его без persistent state (см. секцию выше).

**Когда workaround всё ещё нужен (если когда-нибудь понадобится).** Per Gemini research: Bluetooth BLE-кнопки в фоне, CLLocationManager iBeacon wakes, background processing tasks — там Apple не даёт foreground-equivalent token и `Activity.request` действительно бросает `ActivityAuthorizationError.visibility`. Наш случай (Action Button / Control Center / Shortcuts) не один из этих.

## Параллель: ОДНА Activity, два слота в ContentState, рендер по приоритету

Диктовка и long идут параллельно (`fact-voice-record.md::Параллельная запись`), но `Activity<RecordingAttributes>` строго **одна** (вторая `request()` отменяет первую и съедает pop-out). Поэтому одна Activity несёт **оба слота** в `ContentState` и рендерит **по приоритету**.

**Слоты в `ContentState` (НЕ в attributes).** Раньше `isLongAudio`/`subtitle` были top-level immutable attributes — это переехало в `ContentState`: `phase` (диктовочный слот; `.idle` = диктовка не идёт), `longActive: Bool` + `longSubtitle: String` (long-слот). **Именно потому, что они в mutable ContentState**, одна Activity может на лету переключаться между диктовочным и long-chrome'ом (`update()` меняет ContentState, attributes — нет). Дефолты (`false`/`""`) держат старый persisted ActivityContent декодируемым.

**Производный флаг рендера:** `isLongMode(state) = (state.phase == .idle && state.longActive)`. Весь UI ветвится по нему (НЕ по attributes). Приоритет: **диктовка (phase != .idle) выигрывает богатый chrome** (Island, кнопки, таймер); только когда диктовка idle И long активна — рисуем тихий long-chrome.

**Рефкаунт Activity по двум слотам** (`RecordingActivityManager`): создаётся на первом старте ЛЮБОГО слота, dismiss'ится только когда ОБА idle. API: `dictationStart`/`dictationEnd` (диктовочный слот), `longStart`/`longEnd` (long-слот). Каждый — read-modify-write живого `ContentState` (`liveActivity?.content.state`), чтобы слоты не затирали друг друга. `dictationStart` adopt'ит существующую Activity (kickoff- или long-созданную) и **сохраняет** long-поля; `dictationEnd` при живом long НЕ dismiss'ит — откатывает диктовочный слот в `.idle`, Activity остаётся под long-chrome.

Long-chrome (когда `isLongMode`):
- **ТОЛЬКО Notification Center / Lock Screen — НЕ Dynamic Island.** Юзер: «не надо в шторке вверху, только в центре уведомлений». В ActivityKit НЕТ флага «спрятать Island, оставить NC». Решение: при `isLongMode` **все** Island-слоты рендерят `EmptyView()` → pill схлопывается в голый camera-cutout, NC-карточка остаётся. `EmptyView` статичен → Шрам 3 не грозит. (Когда диктовка идёт параллельно — Island показывает диктовку, это нормально, приоритет.)
- **НИКАКИХ alert'ов для long-перехода.** `longStart`/`longEnd` шлют `update()` без `alertConfiguration`. Иначе pop-out мигнул бы пустым схлопнутым pill'ом. Диктовочные `dictationStart`/`dictationEnd` свои alert'ы сохраняют.
- **Иконка — `recordingtape`, белёсая** (`.white.opacity(0.9)`), не красная. `PhaseIcon` для long статичный, без pulse.
- **Правый слот NC-карточки ПУСТОЙ.** `actionCluster` рендерится только для диктовки (`if !longMode`). Никаких Stop/Cancel для long в LA — long нельзя убить случайным тапом, **единственная** точка стопа/отмены — кнопки в long-панели на главном экране.
- **Вторая строка — статичный текст** «Ожидает команды…» (`phaseLine` при `isLongMode`), не `запись_NNN` и не таймер. Таймер живёт на главном экране (`longRecordingPanel`). Формулировка ещё дозревает под модель «приложение — фоновый слушатель команд» — менять смело.
- **Мик-строка: built-in iPhone как просто «iPhone»** (не «Микрофон iPhone»). `micLabel`: `kind == .iphone` → short-circuit ДО проверки name; AirPods/наушники/USB сохраняют описательный port-name.

**Где ещё рендерится long-карточка (NC) — строго статично** (`Image(systemName:)` only). Отсутствующий SF Symbol падает в blank silently, не fault'ит.

**Long и kickoff-adopt.** `LiveActivityKickoff` (widget extension, диктовка-only) при adopt'е существующей Activity теперь **сохраняет** long-поля (`var state = existing.content.state` + правит только диктовочные поля) — чтобы Control-Center/Action-Button старт диктовки поверх идущего long не стёр его chrome.

**Грабли при добавлении (Swift result-builder).** `@ViewBuilder`-хелперы (`phaseLine`/`compactLeadingIcon`/`minimalView`/`compactTrailingView`) НЕ допускают early `return view; switch…` — паттерн `if isLong { Image…; return }` даёт «non-void function should return a value» + «opaque return type has no return statements». Нужен честный `if isLong { … } else { switch … }`. `AlertConfiguration(body:)` ждёт `LocalizedStringResource`: тернарник через `let x: String` НЕ авто-конвертится — собирать весь `AlertConfiguration` тернарником, чтобы строковые литералы конвертились по месту.

## Связанное

- `fact-voice-record.md` — overall Voice subsystem.
- `fix-dynamic-island.md` — серия шрамов как iOS видит/не видит Activity.
