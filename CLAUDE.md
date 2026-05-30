# Habit Tracker (SwiftUI)

<instructions>
  <step index="1">
    Перед изменением подсистемы, в которой ещё не читал документацию в этой сессии — вызови `mcp__knowledge__docs_search` с запросом про симптом/тему задачи. Haiku-роутер вернёт релевантные `docs/knowledge/` и `docs/methodology/` файлы. Прочитай те что вернулись через Read.

    НЕ читай файлы наугад — `docs_search` сам решит что нужно. НЕ читай весь `docs/knowledge/` сразу — это сжигает контекст.
  </step>
  <step index="2">
    Knowledge-файлы — это **constraints**. Каждый паттерн, helper, инвариант, описанный в knowledge/, ОБЯЗАТЕЛЕН к применению. Нарушение knowledge-правила = баг.
  </step>
  <step index="3">
    После применения изменений — `./deploy.sh` устанавливает на iPhone беспроводно. Если деплой меняет публичное поведение или вводит новый паттерн — обнови соответствующий `knowledge/fact-*.md` или `methodology/*.md`.
  </step>
</instructions>

## Обзор проекта

Нативное iOS-приложение для трекинга привычек на SwiftUI с интегрированной голосовой диктовкой через Soniox + Live Activity. Фокус на жестах, минимализме, iOS 26 Liquid Glass виджетах.

## Технический стек

- **Swift 6.0+ / SwiftUI** (iOS 18+ target, deploy на iOS 26.4 device).
- **Хранение:** `UserDefaults` + JSON-дамп в App Group `group.com.fedor277.habittracker` (виджет и Voice читают тот же контейнер).
- **Виджеты:** WidgetKit с `contentMarginsDisabled()` + `.widgetAccentable()` для Liquid Glass tinted-режима.
- **Voice:** Soniox WebSocket ASR + ActivityKit Live Activity + AppIntents (Shortcuts / Action Button / Control Center).

## Anti-patterns (запреты с привязкой к коду)

- **Не создавать вторую `Activity<RecordingAttributes>`**, когда первая жива — adopt через `Activity.activities.first`. Создание второй отменяет первую и съедает Dynamic Island pop-out. См. `knowledge/fact-live-activity.md::Kickoff from widget extension + adopt pattern`.
- **Не строить persistent `.idle` Activity workaround для «Activity.request from background»**. На iOS 17+ `LiveActivityIntent.perform()` foreground-equivalent для `Activity.request()` — workaround устарел. Workaround применим только если intent НЕ conform'ит LiveActivityIntent (BLE кнопки, location wakes). См. `knowledge/fact-live-activity.md::Persistent .idle mode [deprecated]`.
- **Не возвращать `.result()` из background AppIntent recording-stop без `AVAudioSession.setActive(false, [.notifyOthersOnDeactivation])`** — jetsam watchdog `0x8badf00d` SIGKILL'ит процесс через 2-7с. Точка решения: `RecordingActivityManager.end()` через флаг `stopOriginatedFromIntent` (ставится в `RecordingCoordinator.handlePending` case "stop"). In-app stop через UI-кнопку deactivate'ить НЕ должен (нет музыкальной дыры). См. `knowledge/fix-background-intent-crashes.md::Jetsam`.
- **Не писать `UIPasteboard.general.string = ...` из background-intent контекста** (когда нет connected `.foregroundActive` scene). iOS Pasteboard daemon silent-no-op'ит. Решение: intent возвращает `some IntentResult & ReturnsValue<String>`, юзер собирает Shortcut «Toggle Voice Record → Copy to Clipboard». См. `knowledge/fix-background-intent-crashes.md::Background clipboard`.
- **Не использовать `applicationState` для distinction «foreground vs background» в Intent контексте.** `LiveActivityIntent.perform()` поднимает scene в `.active` activation state даже без видимого UI. Единственный надёжный признак — кто инициировал action: `RecordingCoordinator.toggle()` напрямую (in-app UI) vs `handlePendingActionIfNeeded` (любой intent).
- **Не вызывать `AVAudioSession.setActive/setCategory/setPreferredInput` на main thread.** Apple SDK header: «synchronous (blocking) operation», на BT route — 1-3с handshake. UI замерзает. Только на dedicated `audioQueue: DispatchQueue` (qos: .userInitiated). См. `knowledge/fact-audio-session.md::Blocking API`.
- **Не добавлять анимации (`ProgressView` indeterminate, `pulse` через `.onAppear`) в `compactLeading/compactTrailing/minimal` views Dynamic Island.** SpringBoard рендерит их out-of-process и при fault'е дропает Island целиком. Только статичные `Image(systemName:)` и `Text(timerInterval:)`. См. `knowledge/fix-dynamic-island.md::Шрам 3`.
- **`AppShortcutsProvider` — только в main app target**, не в widget extension. Shortcuts.app сканирует только main app. Если файл шортката доступен только через FS-sync widget'а — добавить explicit reference в main target. См. `knowledge/fact-voice-record.md`.
- **`NSSupportsLiveActivities` обязателен в ОБОИХ Info.plist** (main app + widget extension). Иначе `Activity.request()` возвращает валидный ID, но не рендерит. См. `knowledge/fact-live-activity.md`.
- **Не делать on-device Wake-on-LAN для пробуждения Mac — пробовали, отклонили.** Unicast-magic-packet будит только ~5 мин после засыпания (потом ARP-запись истекает, кадр дропается), broadcast закрыт `multicast`-entitlement'ом (недоступен free Apple ID), sleep-proxy нет. Фичу удалили, юзер выбрал «не усыплять Mac». Надёжный wake потребовал бы always-on relay в LAN. Не переизобретать. См. `knowledge/fix-пробуждение-mac.md`.

## Tabs

Voice — **первая** вкладка (default at cold-start); Habits — вторая. Habit-виджет deep-link'ает в Habits через `habittracker://habits`. Детали — `knowledge/fact-voice-record.md::Tabs` и `knowledge/fact-habit-widget.md::Deep-link`.

## Деплой

Сборка и установка на физический iPhone — одной командой:

```bash
./deploy.sh
```

Wireless через WiFi, USB не нужен. Сертификат бесплатного Apple ID живёт ~7 дней — для обновления просто запустить `./deploy.sh` снова. Детали — `knowledge/fact-wireless-deploy.md`. Самый частый баг после обновления Xcode — `knowledge/fix-coredevice-no-provider.md`.

## Документация

- `docs/knowledge/` — `fact-*` (механика) и `fix-*` (шрамы). Активируется автоматически через `docs_search`.
- `docs/methodology/переносимый-дизайн.md` — переносимые UX-принципы, применимы в любом проекте.
- `docs/methodology/диагностика-apple.md` — диагностика Apple-tooling (Xcode/devicectl/wireless deploy): детерминированные тесты вместо метода исключения, идемпотентность скриптов. Проектно-специфичный flow, не общая тема.
- `docs/methodology/сценарии-использования.md` — пошаговые user-flow через состояния системы (foreground/background/killed) + edge-states. При изменении voice-flow обязательно сверь со сценариями.

Не читай ВСЕ файлы knowledge при старте сессии. `docs_search` найдёт нужные 2-4 файла по симптому.
