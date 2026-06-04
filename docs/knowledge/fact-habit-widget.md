# Habit Widget — Home Screen виджет (iOS 26 Liquid Glass)

Виджет показывает текущий прогресс по привычкам прямо на Home Screen. Размеры **Small (2×2)** и **Medium (4×2)**. Datasource — App Group `group.com.fedor277.habittracker`.

## Liquid Glass — `.widgetAccentable()` обязателен

В iOS 26 виджеты на Home Screen рендерятся в стиле «стекла» — система накладывает прозрачность и tinting. В **tinted-режиме** (юзер выбрал монохромную палитру виджетов) система **окрашивает только элементы помеченные `.widgetAccentable()`**, остальное превращается в нечитаемое белое пятно.

**Что помечать:**
- текст названий привычек;
- иконки слева от названия;
- кружки прогресса (точки в сетке).

Без `.widgetAccentable()` виджет работает в стандартном режиме, но в tinted рассыпается. Это invisible — в Xcode preview tinted-режим не воспроизводится, обнаруживается только на устройстве с переключателем «Виджеты → Однотонные» в Customize Home Screen.

Дополнительно — мониторинг `@Environment(\.widgetRenderingMode)` если нужна явная адаптация контента (например упростить layout в `.accented`).

## contentMarginsDisabled — отступы 4-8pt вместо системных 16

`contentMarginsDisabled()` отключает Apple-defaults `16pt` со всех сторон. Без этого на Small (2×2) теряется ~30% полезной площади. Применяемые внутренние padding'и:
- **Small (2×2)**: `8pt` — позволяет уместить до 6 привычек × 4 дня.
- **Medium (4×2)**: `14pt` — больше пространства, больший шрифт точек (18px) и текста (13pt).

Trade-off — Liquid Glass tinting расплывается прямо к краю при `padding=0`. Минимальный читаемый отступ ≥ 4pt держим вручную. Принцип общий — `methodology/переносимый-дизайн.md::contentMarginsDisabled`.

## Глобальные правила layout

- **Alignment**: контент прижат к верху (`top`), внизу — `Spacer()` чтобы виджет «не плавал» по центру.
- **Localization**: 2-буквенные русские сокращения дней (ПН, ВТ, …) — см. `fact-habit-tracker.md::Локализация`.
- **Text behavior**: названия привычек используют `.truncationMode(.tail)`, **шрифт не уменьшается** при нехватке места — лучше обрезать с многоточием, чем сделать unreadable «10pt мелочь». Юзер привык читать обрезанные названия и достраивает их в голове.
- **Variant A (default Small)**: 5 дней × 4 привычки. Variant B/C/D — альтернативные плотности, юзер выбирает в Customize.

## Widget Sync — App Group + reloadAllTimelines

Datasource живёт в `UserDefaults(suiteName: group.com.fedor277.habittracker)` как JSON-дамп `StorageData`. Виджет имеет **read-only** доступ — pipeline владения данными в main app.

**Trigger:** при каждом save (toggle привычки, edit, reorder) main app вызывает `sharedDefaults.synchronize()` **затем** `WidgetCenter.shared.reloadAllTimelines()`. `synchronize()` обязателен — без него последняя запись может ещё лежать в in-memory buffer и виджет прочитает stale-data. См. `fix-ios-stability.md::App Groups Permissions`.

## Deep-link в Habits tab

Тап по виджету открывает app **сразу на Habits tab** (третья вкладка из Voice · Remote · Habits), не на Voice (default). URL-схема: `habittracker://habits`. `TabRouter` обрабатывает host=`habits` (и legacy `home` для старых виджетов). Детали — `fact-voice-record.md::Tabs` (там же про Voice как default).

## Связанное

- `fact-habit-tracker.md` — основной flow привычек в app.
- `fix-ios-stability.md` — duplicate models, App Group sync, widget rendering.
