# Крахи host app в background-intent контексте

Серия race conditions и system policy violations, проявляющихся когда `ToggleVoiceRecordingShortcutIntent.perform()` запущен из killed-state / backgrounded app через Action Button или Control Center. Каждый шрам — несколько итераций отладки, корень контринтуитивен.

## Симптом: процесс умирает после успешного stop'а через Action Button

Юзер нажимает Action Button → запись стартует → нажимает снова → запись финализируется (видно `[Coord] phase stopping → idle` в логах) → **2-7 секунд тишины** → новый процесс cold-launch'ится (history counter `[Coord] init` инкрементится на 1). Активный alert от Apple «приложение перестало работать» если юзер был в нашем app foreground.

## Jetsam 0x8badf00d watchdog: суспендный app с active recording session

**Корень.** Apple iOS 18+/26 жёстко форсит: app которое **суспендится** удерживая `.playAndRecord` active session → SIGKILL через 2-10с после suspension. Это **не** memory jetsam (`EXC_RESOURCE` / `0xdead10cc`), а отдельный watchdog 0x8badf00d («ate bad food») за «privacy/resource violation». В контексте background AppIntent: когда `perform()` возвращает `.result()`, AppIntents framework снимает свой execution assertion → app переходит в `.suspended`. Если `AVAudioSession` всё ещё `.active` — kill гарантированный.

Источник: Gemini 3.1 Pro research grounded across Apple Dev Forums + Reddit r/iOSProgramming. Подтверждено сравнением логов: на in-app stop через UI-кнопку (нет deactivate) процесс **не** падает потому что scene foreground-active, suspension не наступает.

**Фикс.** В `RecordingActivityManager.end()` перед реальным `act.end()` — `AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])`. Условие — флаг `RecordingCoordinator.shared.stopOriginatedFromIntent`. Флаг ставит `handlePendingActionIfNeeded` на «stop» branch'е (`case "stop"`), сбрасывает `didStopWith` после `end()` consume'ит.

Почему не `applicationState` или `connectedScenes`: `LiveActivityIntent.perform()` временно поднимает scene в `.active` activation state даже без видимого UI, поэтому `UIApplication.shared.applicationState` возвращает `.active` (raw=0) во время background-intent run'а. И `connectedScenes` lag'ает на runloop turn. Единственный надёжный признак — кто инициировал stop: in-app UI-кнопка идёт через `RecordingCoordinator.toggle()` напрямую, минуя `handlePending`. Action Button / Control Center / Shortcuts ВСЕГДА идут через App Group flag + `handlePending`.

**Цена.** Hardware Bluetooth route reconfig на `setActive(false)` — ~1с дыра в фоновой музыке. Это **аппаратное** ограничение Apple QA1631: любая session reconfiguration вызывает audio graph flush, не лечится software'ом. Production apps (Wispr Flow, Superwhisper) делают так же — accept the gap. Дыра визуально замаскирована под `.ended` pop-out banner («Готово — текст скопирован») который юзер смотрит в этот момент.

**Graveyard.**
- Условный deactivate при `applicationState != .active` — `applicationState` врёт в Intent контексте, deactivate не срабатывает в half случаев, kill возвращается.
- Условный deactivate при `connectedScenes.isEmpty` — lag, тоже промахивается.
- Условный deactivate по timestamp (`Coord.init` < 5с назад = cold-launch) — пропускает live-process Shortcut case'ы где app давно в фоне, kill через 3-7с.
- Категория-флип на `.ambient` перед deactivate — категория сама вызывает route flush, дыра идентичная.
- engine.stop + removeTap без `setActive(false)` — watchdog мониторит session.active, не engine. Kill сохраняется.

## Continuation double-resume в `Coordinator.stop()`

**Симптом.** Process умирает прямо в момент `didStopWith` finalize, между `[Coord] phase stopping → idle` и `[Coord] stop() — returned`. В Swift Concurrency invariant: `CheckedContinuation must only be resumed once` — fatal.

**Корень.** Старый код использовал `withTaskGroup` с двумя tasks: один await'ил `session.stop()` (async, но returns ~мгновенно — только посылает finalize frame в Soniox WS и арм'ит watchdog Task), второй был 4с safety sleep. Continuation резюмилась из `didStopWith` delegate. **Но** group.next() возвращался от первой task'и (session.stop() вернулась) → group.cancelAll() → continuation не вызвана → didStopWith позже зовёт `c.resume()` на уже-завершённом контексте → double-resume crash.

**Фикс.** Убран TaskGroup. Структура: одна `withCheckedContinuation { c in ... }`, `stopContinuation = c` ставится **до** `session.stop()`. Resume — только из `didStopWith` после полной финализации. Safety timer 4с — отдельный `Task` который атомарно nil'ит `stopContinuation` перед resume → didStopWith видит nil и не дёргает второй раз. Single-resumer invariant сохранён.

## ActivityKit exception на update/end к dismissed Activity

**Симптом.** `[LA] activityState → dismissed` от системы → host process крашится мгновенно. В логах нет нашего `[LA] end — dismissed` потому что мы не успели его вывести — exception в `act.update()` или `act.end()` убил.

**Корень.** `AlertConfiguration` на `setPhase(.stopping)` инициирует system-side stale → dismissed transition. Race с нашим `RecordingActivityManager.end()` который await'ит свой alerted update + 1.5s + `act.end()`. Если system dismissed Activity до того как наш await-chain дойдёт — `update/end` на не-active Activity бросает exception, ActivityKit cleanup в widget process не справляется и валит host.

**Фикс.** В каждом методе что мутирует Activity (`setPhase`, `setStreaming`, `setPreviewText`, `end`) первой строкой:
```swift
if act.activityState != .active {
    VRLog.d("LA", "method — Activity not active (state=\(act.activityState)), skipping")
    return
}
```
Просто bail safely. Activity уже dismissed системой, наш cleanup не нужен.

## Reconcile-stopping race с didStopWith

**Симптом.** В логах: stop через Shortcut → `[Coord] handlePending: action=stop` → `phase recording → stopping` → `willEnterForeground` (от scene activation в intent context) → `reconcile: persisted=false but engine recording — restoring` → `syncSharedState isRecording=true` ровно когда `didStopWith` уже летит. Состояние рассинхронизировано → crash в финализации.

**Корень.** `reconcileWithControlAfterForeground()` определяет «is engine actually running» через `phase == .recording || phase == .starting || phase == .stopping`. Когда intent на foreground поднимает scene во время stop'а, `phase` ещё `.stopping`, `actuallyRunning=true`, persisted уже `false` (его установил `syncSharedState` в начале stop'а). Reconcile решает «App Group рассинхронизирован» и **переписывает обратно** `isRecording=true`, гонка с `didStopWith` финализацией → crash.

**Фикс.** Исключить `.stopping` из «actuallyRunning». В `.stopping` stop уже принял решение и идёт по запланированному пути — reconcile не должен вмешиваться. Дополнительно: `persisted && !actuallyRunning && phase != .stopping` — двойной гвард на случай других race-окон.

## Background clipboard: silent no-op без foreground scene

**Симптом.** Stop через Shortcut → юзер открывает Notes → жмёт Paste → пусто. Текст появляется в clipboard **только** когда юзер возвращается в наше app (через willEnterForeground flush из `pendingClipboardText` в App Group).

**Корень.** Apple Pasteboard daemon (`com.apple.UIKit.pboard.general`) проверяет audit token caller'а против foreground scene state. Background-launched intent perform() не имеет connected `.foregroundActive` scene → write silently dropped. Не throw'ит, не возвращает error — просто игнорирует. iOS 17/18/26 — поведение одинаковое, не лечится. Custom UIPasteboard categories, `setItems:options:`, beginBackgroundTask wrap — ничего не помогает (Gemini 3.1 Pro research grounded across Reddit r/iOSProgramming, r/swift).

**Фикс.** Intent возвращает `some IntentResult & ReturnsValue<String>` — транскрипт как value. Юзер собирает Shortcut в Shortcuts.app: action 1 «Toggle Voice Record» (наш intent), action 2 «Copy to Clipboard» с Magic Variable из step 1. Shortcuts.app пишет clipboard с **системными** privilege'ами (она foreground-equivalent для всех своих action'ов). Привязывает шорткат к Action Button.

**Production reality.** Wispr Flow в App Store review explicitly: *«switching keyboards all the time is insane. Also copying into clipboard and dictation under button doesn't start stop properly»*. Superwhisper: *«Clicking the record button starts the recording, but hitting stop doesn't actually paste the text»*. Aiko docs: *«iOS apps are fundamentally restricted from operating in the background for extended periods»*. Никто не решил — все либо требуют custom keyboard extension, либо foreground re-open, либо Shortcuts pipeline (наш путь).

## Force-quit прерывает фоновую музыку — system-level, не лечится

Когда юзер swipe-up'ом убивает наш app из App Switcher, iOS SIGKILL'ит процесс и **сам** деактивирует все его audio session'ы. Эта системная деактивация неявно посылает `interruption-ended` другим audio app'ам → плеер перехватывает A2DP роут → секундная пауза. Наш код в этот момент уже мёртв, повлиять нельзя.

Apple Dev Forum threads (2024-2026) задокументировали: `applicationWillTerminate` не вызывается при force-quit (только при нормальном завершении), `UIApplication.willTerminateNotification` тоже не доходит. Дев не может сделать «graceful release» перед kill'ом. Нашёл на тестах юзера, не воспроизводится в нормальном use case (юзеры редко force-quit'ят).

## Связанное

- `fact-voice-record.md::Killed-state Toggle` — dual-conformance pattern + ReturnsValue<String>.
- `fact-audio-session.md` — почему deactivate вообще делает hardware flush.
- `fact-live-activity.md::activityState guard` — защита от Activity-dismissed exception.
- `methodology/переносимый-дизайн.md::Background-trigger = system suspend` — обобщённый принцип.
