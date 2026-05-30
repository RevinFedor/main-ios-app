# Activity видна в Notification Center, НО НЕ в Dynamic Island

## Симптом

Юзер нажал Toggle → `[LA] start — activity ... state=active` в логе → `activityState → active` подтверждено iOS → но в Dynamic Island compact (область рядом с Face ID) **пусто**. Свайп вниз шторку → Activity висит в Notification Center. На Lock Screen — тоже видна. **Только Island compact пустой.**

## Шрам 1: NSSupportsLiveActivities только в app, не в widget

**Проявление:** `Activity.request()` возвращает валидный ID, в логе activityState=`.active`, но **вообще ничего** не рендерится (даже в NC).

**Корень:** ключ был только в `HabitTracker/Info.plist`. В `HabitWidget./Info.plist` отсутствовал. Apple требует в обоих target'ах — иначе widget extension'у не доверяют рендеринг ActivityConfiguration.

**Решение:** добавить `NSSupportsLiveActivities=true` + `NSSupportsLiveActivitiesFrequentUpdates=true` в **оба** Info.plist.

## Шрам 2: relevanceScore сбрасывается при update без явной передачи

**Проявление:** Activity появилась в Island на момент `Activity.request()` (score=1.0), но через ~1.4 сек (когда Coordinator делает первый `setPhase(.recording)` через `update()`) — пропала из Island. Осталась в NC.

**Корень:** `ActivityContent(state:, staleDate: nil)` без relevanceScore — default `0.0`. iOS даёт compact slot activity с наивысшим score. Другая работающая Activity (Яндекс.Доставка) с любым score>0 нас вытесняла.

**Решение:** константа `pinnedRelevance: Double = 100.0` в `RecordingActivityManager`, передаётся в **каждый** `ActivityContent(...)` (start, setPhase, setStreaming, setPreviewText, end). Также helper `freshStaleDate() = Date() + 8h` — на всякий случай, хотя `nil` Gemini Pro подтвердил как безопасный.

## Шрам 3: SwiftUI fault в compact/minimal closures → SpringBoard drop

**Проявление:** Activity в NC видна, в Island compact — пусто. relevanceScore=100, staleDate set. activityState→.active. Ничего не помогает.

**Корень:** compact `compactLeading/compactTrailing` и `minimal` views рендерятся **out-of-process** SpringBoard'ом. Когда closure faulть на runtime — repeating animation через `.onAppear { pulse = true }`, indeterminate `ProgressView`, missing image asset — SpringBoard self-defending снимает Island view целиком (NC path рендерится отдельно in-process, остаётся работать).

Gemini Pro: *"This happens when your Dynamic Island SwiftUI closures crash at runtime. Common triggers include forced-unwrapping nil, missing image assets, or exceeding strict WidgetKit layout constraints. To protect SpringBoard from crashing, iOS silently unmounts the Dynamic Island views but continues safely rendering the Lock Screen/Notification Center lockScreen closure."*

**Решение:** в compact/minimal — только статичные `Image(systemName:)` и `Text(timerInterval:)` (primitive timer, system-managed). Никаких:
- `PhaseIcon` с pulse animation → перенесён в lockScreen-only.
- `ProgressView()` индикаторов → заменены на `Text("•••")` (статично).
- `.onAppear` side effects в compact.

## Шрам 4: pop-out animation вообще не играется

**Проявление:** Activity появляется в Island compact, но без анимации "выезд большой банер сверху → сворачивание в Island". Юзер видит mic icon мгновенно без feedback'а.

**Корень А:** `Activity.request()` сам по себе **НЕ играет** pop-out. Apple-policy: чтобы каждое создание Activity не спамило банером. Pop-out играется только через `Activity.update(content:alertConfiguration:)` с non-nil `AlertConfiguration`.

**Что пробовали:**
1. Только `Activity.request()` — нет pop-out.
2. `Activity.request()` + immediate alerted `update()` из main app target после поднятия app в foreground — alert suppressed (iOS подавляет banner-style notifications для активного app).

**Корень Б:** AlertConfiguration suppressed когда app в foreground. By-design — то же что обычные UNUserNotifications: Apple считает банер избыточным когда юзер смотрит на app. **Workaround'а на ActivityKit-уровне нет** (`UNUserNotificationCenterDelegate.willPresent` не применим к LA-alerts).

**Решение:** `Activity.request` + immediate alerted `update` **из widget extension process** (background, не foreground). `LiveActivityKickoff.requestIfNeeded()` живёт в `HabitWidget./`, вызывается в `Intent.perform()` ДО `postPendingAction` (т.е. до того как app поднимется). После — main app поднимается, `RecordingActivityManager.start()` adopt'ит существующую Activity вместо создания второй (которая бы отменила первую и съела pop-out).

## Шрам 6: Adopt без state reset = таймер показывает 27 минут + lazy NC update

**Релевантность.** На текущий момент persistent `.idle` mode снят как ненужный workaround (см. `fact-live-activity.md::Persistent .idle mode [deprecated]`). Шрам сохраняется в логике `start()` adopt-branch'а на случай если persistent режим когда-нибудь вернётся (BLE-кнопки, location wakes); пока — defensive code.

**Проявление:** persistent `.idle` Activity провисела ~27 минут (юзер не записывал). Юзер тапает Toggle → setPhase(.recording) → в Lock Screen / Notification Center таймер сразу показывает **27:00** вместо 0:00. Дополнительно: NC обновляется лениво — название и таймер появляются через ~6 секунд после tap'а, хотя вибрация ощущается мгновенно.

**Корень А (timer=27:00).** `RecordingAttributes.ContentState.startedAt` был установлен при первом создании Activity (когда юзер включил «Закреп.»). При adopt'е в `RecordingActivityManager.start()` мы reuse'или existing state — `startedAt` оставался 27-минутной давности. SwiftUI `Text(timerInterval: state.startedAt ... .distantFuture, countsDown: false)` рендерит «27:00» сразу же.

**Корень Б (lazy NC).** Первый `update()` после adopt был без `alertConfiguration`. Apple ленится с rerender NC/Lock Screen surface если update не alerted — пересчёт через 4-6 секунд по системному таймеру. С alertConfiguration iOS рендерит немедленно (≤1с) — это часть «alert priority» механики.

**Решение:** при adopt'е (`RecordingActivityManager.start()` AND `LiveActivityKickoff` existing-activity branch) — полный **пересоздание `ContentState`** с свежими значениями (`startedAt = Date()`, `isStreaming = false`, `previewText = ""`, `endedAt = nil`, `phase = .starting`) и `update(content, alertConfiguration: AlertConfiguration(...))` с silent sound. Не mutate существующий state — создавать новый.

```swift
// При adopt:
let state = RecordingAttributes.ContentState(
    startedAt: Date(),
    isStreaming: false,
    endedAt: nil,
    previewText: "",
    phase: .starting
)
await pre.update(
    ActivityContent(state: state, staleDate: Self.freshStaleDate(), relevanceScore: Self.pinnedRelevance),
    alertConfiguration: AlertConfiguration(title: "Voice Record", body: "Запись началась", sound: .named(""))
)
```

## Шрам 5: Active mic system-claim вытесняет Activity в minimal

**Проявление:** во время recording наш Activity показывается **не в compact**, а в minimal slot (точка с mic-icon, без timer'а).

**Корень:** privacy-policy iOS. При активном микрофоне iOS показывает свой **orange dot indicator** в compact Dynamic Island, и **демотит** все non-system Live Activities в minimal slots по бокам. Перебить нельзя.

**Решение:** в `minimalView` показываем `Text(timerInterval:)` в `.recording` фазе вместо просто `mic.fill` — юзер видит секунды и минуты даже когда iOS форсит multi-LA в minimal-mode.

## Диагностические логи

`RecordingActivityManager` подписывается на `activity.activityStateUpdates` через async stream:
```swift
for await s in activity.activityStateUpdates {
    VRLog.d("LA", "activityState → \(s)")
}
```
Видно если iOS принудительно дропнула Activity (`.stale` / `.dismissed`) или удержала (`.active` до явного `end()`). При `.active` всё время — наша проблема (state/view), при `.stale`/`.dismissed` за 2-3с — system override.

## Связанное

- `fact-live-activity.md` — общие правила Live Activity (relevanceScore, AlertConfiguration, adopt pattern).
- `fact-voice-record.md` — overall Voice subsystem.
