# Habit Tracker (SwiftUI)

<instructions>
  <step index="1">
    Перед изменением подсистемы, в которой ещё не читал документацию в этой сессии — вызови `mcp__knowledge__docs_search` с запросом про симптом/тему задачи. Haiku-роутер вернёт релевантные `docs/knowledge/` и `docs/methodology/` файлы. Прочитай те что вернулись. Исключением является случай, если ты сейчас в активной разработке и уже изменил много кода, и в самом начале документация уже читал. Тогда заново перечитывать не нужно.
  </step>
  <step index="2">
    Knowledge-файлы — это **constraints**. Каждый паттерн, helper, инвариант, описанный в knowledge/, ОБЯЗАТЕЛЕН к применению. Нарушение knowledge-правила = баг.
  </step>
  <step index="3">
    После применения изменений — `./deploy.sh` устанавливает на iPhone беспроводно.
    НЕ обновляй документацию без ЯВНОГО приказа пользователя. Файлы `docs/` (`knowledge/`, `methodology/`, `fact-*`, `fix-*`) — НЕ создавать и НЕ редактировать, пока пользователь прямо не попросил. Закончил фичу/фикс → ОСТАНОВИСЬ, не пиши доки «заодно» / «по итогам» / на каждой итерации. Причина: пользователь сначала сам проверяет код; документация по непроверенной итерации = мусор, который придётся откатывать. Это всегда отдельный явный шаг.
  </step>
</instructions>

## Локальная long-запись: НЕ пушить

В этом клоне есть локальная недоделанная функциональность long-записи / фоновой лог-записи. Она нужна только для локальной full-сборки пользователя и **ни при каких обстоятельствах не должна попадать в git / GitHub**.

Сейчас она удерживается локально через `git update-index --skip-worktree`, а не через runtime-флаг приложения. Это состояние хранится только в локальном git index. Перед любым commit/push по Voice/Live Activity обязательно проверь:

```bash
git ls-files -v | rg '^S '
git grep -E 'recordingtape|isLong|longActive|toggleLong|LongAudioFileWriter' HEAD -- HabitTrackerSwift
```

Ожидание: long-файлы остаются с префиксом `S`, а `git grep -E ... HEAD -- HabitTrackerSwift` ничего не находит. Не снимай `skip-worktree` с этих файлов и не добавляй long-запись, long-плашки, long-историю, long Live Activity поля или связанную локальную лог-запись в коммиты без прямого приказа пользователя.

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
- **Не строить AI Chat history drawer на SwiftUI `DragGesture` / hidden `UIViewRepresentable` superview bridge.** Это root-level custom container transition, конкурирующий с `UIScrollView`, search/text input, iOS 26 back-swipe и tab bar. Compact iPhone drawer делается через `UIGestureRecognizerRepresentable` + кастомный `UIPanGestureRecognizer` с intent-lock и scroll arbitration; regular width — `NavigationSplitView`. См. `knowledge/fact-voice-chat-tab.md::History drawer gesture`.
- **Не возвращать Terminal `projects/tabs/chat` навигацию на SwiftUI `.offset` / snapshot / bitmap overlay.** Для интерактивного back-swipe и стабильного scroll ownership граница уровней живёт в UIKit-owned container (`TerminalUIKitNavigationController` + `UITableView` для projects/tabs). См. `knowledge/fix-ios-stability.md::Terminal navigation jank`.

## Стандарт long-press (единый по проекту)

Длительное зажатие строки/заголовка (карточка чата, вкладка терминала, проект, строка истории) = **нативный SwiftUI `.contextMenu`**, не кастомный жест. Он сам даёт платформенный feel, который юзер принял за эталон: мгновенный lift+scale элемента, haptic через ~0.1-0.2с, затем выпадающее меню. Действия в меню — лёгкие (Rename / Copy / Delete). Rename открывает bottom-sheet (`presentationDetents([.height(220),.medium])`, Cancel слева / Save справа, автофокус) — эталон `VoiceChatTitleEditorSheet` / `CTRenameSheet`. Не изобретать кастомный scale+haptic+popover там, где `.contextMenu` подходит (методология «Нативный компонент vs кастом»). Кастомный long-press оправдан ТОЛЬКО когда `.contextMenu` структурно не подходит (reorder-драг — там UIKit long-press recognizer, см. `fact-habit-tracker.md::Перестановка`).

Переименование терминальных вкладок/проектов с телефона: вкладка — `POST /api/sdk-tabs/:id/rename` (уже было, ставит `nameSetManually`), проект — `POST /api/projects/:id/rename` (`renameProject` bridge → `updateProject{name}`). Оба в custom-terminal, оптимистично применяются в `TerminalControlStore`.

## Tabs

Voice — **первая** вкладка (default at cold-start); Habits — вторая. Habit-виджет deep-link'ает в Habits через `habittracker://habits`. Детали — `knowledge/fact-voice-record.md::Tabs` и `knowledge/fact-habit-widget.md::Deep-link`.

## Деплой

Сборка и установка на физический iPhone — одной командой:

```bash
./deploy.sh
```

Wireless через WiFi, USB не нужен. Сертификат бесплатного Apple ID живёт ~7 дней — для обновления просто запустить `./deploy.sh` снова. Детали — `knowledge/fact-wireless-deploy.md`. Самый частый баг после обновления Xcode — `knowledge/fix-coredevice-no-provider.md`.

## Логирование (AI Chat)

Нативный чат (`VoiceChatStore.swift::VCLog`) шлёт свои debug-строки на Mac: батч каждые ~3 сек → `POST /api/log` voice-record'а → **`~/Library/Logs/voice-record/ios-chat.log`** (НА МАКЕ, не на телефоне). Параллельно последние строки лежат в локальном буфере телефона: AI Chat Settings → Diagnostics → Show debug log / Copy. Теги: `[SSE]`, `[Store]`, `[Confirm]`, `[Keyboard]`. Дебаг чата = grep `ios-chat.log` рядом с `voice-record.log` + при UI/keyboard багах копия локального лога из settings. Новые подозрительные точки в чате логируй через `VCLog.log(tag, msg)` — попадут в оба места.

## Документация

- `docs/knowledge/` — `fact-*` (механика) и `fix-*` (шрамы). Активируется автоматически через `docs_search`.
- `docs/methodology/переносимый-дизайн.md` — переносимые UX-принципы, применимы в любом проекте.
- `docs/methodology/диагностика-apple.md` — диагностика Apple-tooling (Xcode/devicectl/wireless deploy): детерминированные тесты вместо метода исключения, идемпотентность скриптов. Проектно-специфичный flow, не общая тема.
- `docs/methodology/сценарии-использования.md` — пошаговые user-flow через состояния системы (foreground/background/killed) + edge-states. При изменении voice-flow обязательно сверь со сценариями.

Не читай ВСЕ файлы knowledge при старте сессии. `docs_search` найдёт нужные 2-4 файла по симптому.
