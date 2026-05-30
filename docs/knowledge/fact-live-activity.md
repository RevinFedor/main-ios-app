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

## Lifecycle: end + immediate re-request на каждый toggle

Каждый stop → `end(immediate: true)` → Activity полностью dismiss'ится. Следующий start → новый `request()` из intent perform → новая pop-out. Без полного end re-request не сыграл бы animation (Apple ровно одну на жизненный цикл Activity).

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

## Связанное

- `fact-voice-record.md` — overall Voice subsystem.
- `fix-dynamic-island.md` — серия шрамов как iOS видит/не видит Activity.
