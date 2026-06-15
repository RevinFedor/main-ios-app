# Terminal navigation jank investigation, 2026-06-15

Этот файл - рабочая записка по расследованию лагов Terminal UI на iOS. Это не финальная `knowledge/`-документация и не методология: сюда собраны факты из логов, проверенные гипотезы, изменения кода и текущее состояние, чтобы не потерять контекст перед последующим нормальным обновлением документации.

## Контекст

Проблемная зона: нативный Terminal внутри Voice tab, compact iPhone navigation:

- `projects` - список всех проектов.
- `tabs` - список вкладок выбранного проекта.
- `chat` - конкретная terminal/chat вкладка.
- Отдельно рядом живёт chat drawer / terminal drawer, переключающий поверхность между обычным Voice Chat и Terminal.

Основные жалобы в этой сессии:

- лаг при первом открытии Terminal из верхнего/бокового меню;
- лаги при переходе `projects -> tabs` и `tabs -> projects`;
- иногда верхний terminal header исчезал примерно на 1-2 секунды после возврата на список проектов;
- при быстрых свайпах назад/вперёд были interrupted transitions с dropped frames;
- в terminal chat при стриминге/изменении сообщений scroll мог уходить в пустое пространство;
- иконки Claude/Codex иногда отображались, иногда заменялись fallback-иконкой терминала.

## Что означают ключевые логи

### `[frame]`

Пример:

```text
[frame] window id=6 status=done reason=term-nav label="back from=tabs" frames=62 dropped=15 worst=86ms expected=16.7ms duration=1226ms byPhase[animate=6/29ms settle=9/85ms]
```

Это главный индикатор видимого jank. Важные поля:

- `reason=term-nav` - навигация внутри Terminal.
- `reason=chat-drawer` - открытие/закрытие drawer между Voice Chat и Terminal.
- `label` - конкретный переход: `pushProject`, `pushTab`, `back from=tabs`, `back from=chat`, `drag surface=chat`, `close surface=terminal`.
- `dropped=N` - число кадров, которые вышли за бюджет.
- `worst=XXms` - худший кадр. Всё выше 33ms уже заметно, 50-90ms чувствуется как фриз.
- `byPhase[...]` - в какой фазе случились плохие кадры.

Фазы:

- `mount` - мы подготавливаем/монтируем incoming слой.
- `animate` - собственно slide-анимация.
- `gesture` - палец ведёт интерактивный back gesture.
- `swap` - коммит выбранного project/tab в store.
- `live-mount` - live SwiftUI view уже становится реальным экраном после snapshot/placeholder.
- `settle` - хвост после анимации, где SwiftUI ещё может дорендеривать/перелэйаутить.
- `idle` - вне активной навигации.

Важный вывод: если `worst` сидит в `settle`, это всё равно пользовательский лаг. Анимация визуально уже заканчивается, но UI ещё фризит или дёргается.

### `[TerminalPerfContext]` в хвосте логов

Почти все Terminal-логи теперь дописывают:

```text
nav=nav#7 label="term-nav pushProject name=..." phase=settle age=598ms phaseAge=333ms
```

Это нужно, чтобы понять, попал ли сетевой ответ или publish в хвост текущей навигации. Если `TerminalHTTP GET response` или `TerminalCache tabs load done` приходит при `phase=animate/settle`, он может загрязнить render в самый плохой момент.

### `[TerminalCache]`

Примеры:

```text
[TerminalCache] tabs load start project=... showLoader=false updateSelected=true cached=11 nav=... phase=settle
[TerminalCache] tabs load done project=... changed=false visible=true ... ms=160 nav=... phase=settle
[TerminalCache] prefetch park (interaction active)
[TerminalCache] stale tabs reload wait quiet
```

Что показали эти логи:

- Даже `changed=false` publish может быть вредным, если он трогает observable state в `settle`.
- `/tabs` GET часто приходил не во время network-ожидания пользователя, а прямо в хвост перехода.
- Поэтому refresh/prefetch нельзя считать безобидным только потому, что payload маленький или `changed=false`.

### `[TerminalSSE]`

Примеры:

```text
[TerminalSSE] history publish WAIT interaction tab=... netMs=257 normMs=0 built=28 nav=... phase=settle
[TerminalSSE] history publish park (nav tail)
[TerminalSSE] history publish DROP after wait (tab no longer selected)
[TerminalSSE] event#2 snapshot tab=... status=active busy=false session=... tool=-
```

Что важно:

- История может прийти во время push в chat, но publish entries во время перехода создаёт Text layout и портит кадры.
- Поэтому publish стал ждать quiet window.
- Если пользователь уже ушёл назад, publish надо drop-ать, иначе история старой вкладки мутирует teardown-состояние.
- `tool=-` в snapshot не значит, что картинки должны пропасть. Это только означает, что конкретный SSE snapshot не прислал `toolType/commandType`; тип агента должен сохраняться из tab metadata, session id, color или name.

### `[term-render]`

Пример:

```text
[term-render] row bodies=19 distinct=19 burstMs=759 sample=[...]
```

Этот probe показывает storm пересборки строк. Он полезен, но не является полной картиной:

- если `row bodies` высокий во время `phase=settle`, observable mutations всё ещё гоняют SwiftUI body;
- если `row bodies` низкий, но frame drops есть, причина может быть в compositor/layout/blur/shadow/snapshot, а не в body eval.

### `[TerminalScroll]`

Пример проблемного scroll-лога:

```text
21:10:06.354 phase interacting->decelerating ... off=6139 content=6954 container=715 dist=99 ratio=0.98
21:10:06.388 geom ... dOff=0 dContent=-846 old[off=6103 content=6954 ... dist=136 ratio=0.98] new[off=6103 content=6108 ... dist=-710 ratio=1.13]
```

Это важный симптом: content height резко уменьшился на `846`, offset остался старым, поэтому scroll оказался за новым bottom (`dist=-710`, `ratio=1.13`). Визуально это может выглядеть как пустое пространство, пока пользователь не доскроллит/не заставит ScrollView пересчитать позицию.

Этот scroll-баг в этой сессии только диагностировался логами, но не был исправлен до конца.

## Хронология и факты по итерациям

### 1. Первые логи: лаги не только от сети

Пример раннего случая:

```text
19:46:14.466 pushTab debugging terminal navigation jank
19:46:15.181 frame interrupted ... worst=77ms ... byPhase[settle=4/76ms]
19:46:15.293 history response bytes=2438319 ms=553
19:46:15.312 history publish WAIT interaction
19:46:15.490 history publish DROP after wait (tab no longer selected)
```

Вывод:

- сетевой ответ действительно мог приходить рядом с gesture/back;
- но даже когда publish стали ждать/drop-аться, оставались frame drops;
- значит проблема не сводилась к HTTP latency.

### 2. Tabs reload/prefetch во время навигации

Повторяющийся паттерн:

```text
TerminalCache stale tabs reload wait quiet
TerminalCache tabs load start ... phase=settle
TerminalCache tabs load done ... changed=false visible=true ... phase=settle
```

Что пытались изменить:

- добавили `interactionActive`;
- prefetch/tabs reload стали парковаться, если активна навигация;
- ввели longer quiet window;
- stale reload стал deferred task с cancel/token per project;
- backToTabs стал пропускать reload, если cache fresh.

Что это дало:

- уменьшило количество сетевых writes в середине slide;
- убрало часть случаев, где `/tabs` response прилетал в плохой момент;
- но не убрало основной `pushProject/back from=tabs` jank, потому что live SwiftUI tree всё ещё монтировался/двигался.

### 3. History publish при pushTab/back

Проблема:

- push в chat запускает history load;
- history payload может быть от сотен KB до нескольких MB;
- normalization вынесена off-main, но assign entries всё равно создаёт layout на UI.

Что сделали:

- `history publish WAIT interaction`;
- отдельный `historyPublishIdleGraceMs`;
- если вкладка уже не выбрана - drop after wait;
- cancellation во время rapid back стала штатной, не ошибкой offline.

Эффект:

- back-before-load перестал ломать state;
- лаги chat->tabs заметно снизились;
- pushTab всё равно может показывать `settle=80ms`, если live chat detail монтируется и история публикуется слишком близко к хвосту.

### 4. Snapshot overlay и regression с исчезающим header

Была попытка закрывать live mount snapshot overlay:

- destination после transition коммитился в store;
- поверх live view держался frozen snapshot;
- live view монтировался за snapshot.

Это помогло частично скрыть тяжёлый mount, но вызвало заметный regression:

- `terminalFixedHeader` находился внутри тех же transient views/snapshots;
- когда `terminalSnapshotOverlayActive == true`, header не рендерился;
- при возврате на `projects` верхний bar мог пропадать примерно на 1-2 секунды;
- пользователь видел "то пропадает, то появляется" и дёргание высоты.

Фикс:

- header вынесен в постоянный root-layer `terminalRootHeader`;
- дочерние экраны получают `showsHeader: false`;
- snapshot/back/forward content больше не владеют top chrome;
- install/build/rename/chat header actions перенесены в root header.

Результат:

- исчезновение верхнего bar должно быть устранено архитектурно;
- это не решило все frame drops, потому что jank ниже header продолжил существовать.

### 5. Frozen destination было недостаточно

Перед последней итерацией destination snapshot уже был frozen, но source слой оставался live:

- при `pushProject` source был `TerminalProjectsView`;
- при `back from=tabs` source был `TerminalProjectTabsView`;
- оба могли читать `@Observable` store и пересобираться, пока слой едет.

Логи после root header всё ещё показывали:

```text
21:04:15.311 pushProject docs-01 ... dropped=9 worst=57ms byPhase[mount=2/47ms settle=2/56ms]
21:04:16.098 back from=tabs ... dropped=15 worst=86ms byPhase[animate=6/29ms settle=9/85ms]
```

Фикс:

- добавлен `transitionSourceSnapshot`;
- во время любого horizontal transition `terminalContent` показывает snapshot source, а не live projects/tabs view;
- source snapshot захватывается в `pushProject`, `pushTab`, `beginTerminalBackDrag`;
- после завершения transition snapshot очищается.

Ожидание:

- оба движущихся слоя больше не должны читать live store во время slide.

Фактический результат по логам 21:09:

```text
21:09:53.859 pushProject custom-terminal ... dropped=8 worst=65ms byPhase[mount=3/65ms settle=5/61ms]
21:09:54.443 back from=tabs ... dropped=11 worst=66ms byPhase[animate=8/41ms settle=3/65ms]
21:09:55.930 pushProject sc-desktop ... dropped=3 worst=48ms byPhase[mount=2/48ms settle=1/40ms]
21:09:58.605 back from=tabs cancel ... dropped=2 worst=49ms byPhase[gesture=2/48ms]
```

Вывод:

- улучшение есть не во всех случаях и не радикальное;
- live source churn был не единственной причиной;
- оставшийся jank вероятно связан с compositor/render cost самих SwiftUI snapshot-списков, ZStack/offset, backgrounds, materials/shadows, либо mount cost snapshot view;
- следующий жёсткий шаг - bitmap/UIView snapshot вместо SwiftUI preview view, либо UIKit container transition.

### 6. Иконки Claude/Codex

Факт:

- картинки Claude/Codex не должны подтягиваться по API;
- assets лежат локально в приложении:
  - `Assets.xcassets/ClaudeIcon.imageset/claude.svg`
  - `Assets.xcassets/CodexIcon.imageset/codex.svg`
- API даёт metadata: `toolType`, `commandType`, `color`, session id, tab name, tab type.

Почему иконки "то есть, то нет":

1. `effectiveToolType` раньше сравнивал сырые строки строго:

```swift
toolType == "codex"
commandType == "claude"
```

Если сервер присылал variant/case/empty `tool=-`, mobile мог не распознать агент.

2. Preview rows, добавленные ради плавности, использовали не `AgentIconView`, а упрощённый SF Symbol:

```swift
Image(systemName: tab.isCodexPTY ? "chevron.left.forwardslash.chevron.right" : "terminal")
```

То есть live row могла показывать локальный Claude/Codex asset, а frozen snapshot во время перехода - fallback terminal icon.

Фикс:

- `CTTabInfo.normalizedAgentType(_:)` нормализует `codex`, `gemini`, `claude`, `anthropic`;
- `effectiveToolType` теперь смотрит `toolType`, `commandType`, `color`, `tabType`, session ids, name;
- status/SSE updates нормализуют tool перед записью session id;
- `TerminalTabPreviewRow` теперь использует тот же `AgentIconView(toolType: tab.effectiveToolType, size: 26)`.

Версия с этим исправлением была собрана и установлена на iPhone в 21:14:58.

### 7. Итерация 21:15-21:41: интерактивность, activation parking, scroll-memory, pager leak

После версии 21:14:58 пользователь прогнал серию быстрых переходов. Важные новые факты:

```text
21:15:16.044 pushProject custom-terminal ... cachedTabs=true fresh=true
21:15:16.692 frame ... dropped=6 worst=72ms byPhase[mount=2/54ms settle=4/72ms]
21:15:17.406 back from=tabs ... dropped=11 worst=69ms byPhase[animate=7/25ms gesture=1/33ms settle=3/68ms]
21:36:21.930 pushProject docs-01 ... cachedTabs=true fresh=false
21:36:22.386 frame ... dropped=10 worst=53ms byPhase[animate=6/25ms mount=2/52ms settle=2/52ms]
21:41:23.293 pushProject hh-tool ... cachedTabs=true fresh=false
21:41:24.236 frame ... dropped=12 worst=62ms byPhase[animate=6/25ms mount=3/62ms settle=3/58ms]
```

Выводы по этим логам:

- cache действительно работает: `cachedTabs=true`, prefetch на warm cache пишет `tabs prefetch SKIP cached`, fresh cache даёт `skip tabs reload`;
- при `fresh=false` reload уже парковался (`stale tabs reload wait quiet`, `prefetch park`), но frame drops всё равно оставались;
- значит основная проблема уже не API и не `/tabs` payload, а стоимость самой SwiftUI transition surface;
- ожидание 5 секунд между кликами помогало потому, что успевали закончиться settle-tail, deferred reload и live mount; при быстрых кликах следующий переход начинался поверх хвоста предыдущего.

Параллельно нашли UX/regression от mitigation:

1. `renderSuspended` на странице вкладок сначала показывал lightweight preview без настоящих row buttons. Пользователь видел список, но клик по вкладке "не работал", пока не снималась suspension/не обновлялось состояние. Это было не network-зависание, а неинтерактивная preview surface.
2. Исправление: `TerminalProjectTabsView` и `TerminalProjectsView` в suspended mode теперь рендерят тот же реальный `ScrollView` с `Button` rows, но без тяжёлых context menu / refresh / FAB / spinner-анимаций. То есть surface остаётся кликабельной сразу, если переход уже завершён.
3. `pushTab` стал ждать quiet-window перед `activateSelectedTab`, чтобы history/params/status/SSE не стартовали прямо в хвост slide.
4. В `TerminalScroll` добавлен clamp/re-pin для случая `distFromBottom < -threshold`: если content height резко уменьшился и offset оказался ниже нового bottom, делаем correction scrollTo bottom без user animation.
5. В `TerminalBackPanGesture` разрешили начинать back-swipe поверх row `Button`'ов, запрещая только text inputs. Иначе контейнерный жест проигрывал строке/пейджеру.
6. Списки проектов/вкладок переведены на store-owned `.scrollPosition(id:)`, но пользователь всё ещё видел прыжки: transition preview не сохранял видимый bitmap/offset, а live view пересоздавался после возврата.

Отдельный новый лог:

```text
[pager-leak] LEADING overscroll on chat page while terminal canStepBack=true — back-swipe leaked to pager (black area) offsetX=-18
```

Это означает: nested Terminal мог сделать шаг назад, но root pager всё равно иногда получал горизонтальный right-swipe и показывал чёрную leading rubber-band область. Рядом не всегда был `[term-swipe-miss]`, поэтому это не только порог `TerminalBackPanGesture`; нужен более жёсткий root pager lock, пока `terminalMode && terminal.canStepBack`.

### 8. Текущий архитектурный шаг: bitmap transition layer

Решение после этих логов: перестать двигать SwiftUI preview views вообще. Старое слово "snapshot" было неточным: это были value snapshots, но всё равно SwiftUI-деревья (`TerminalProjectsBackPreview`, `TerminalTabsBackPreview`) внутри `ZStack` с `.offset`. Они могли стоить 50-90ms на mount/render/compositor даже без observable churn.

Новый подход:

- перед переходом снимаем текущую видимую Terminal content surface как `UIImage` из `UIWindow` crop по content rect;
- destination для `tabs`/`chat placeholder` рендерим один раз через `ImageRenderer`;
- сам slide двигает только два `UIImage` слоя (`TerminalBitmapTransitionView`);
- live SwiftUI view монтируется уже под frozen destination bitmap после commit;
- для back-переходов используем cached bitmap предыдущей поверхности (`projects` или `tabs`), поэтому визуальный scroll offset при возврате должен сохраняться хотя бы на время transition;
- root header остаётся постоянным и не входит в bitmap transition;
- root pager теперь лочится на `terminalMode && terminal.canStepBack`, чтобы убрать black overscroll leak.

Ожидаемый новый профиль логов:

- если bitmap path сработал, label будет `bitmap pushProject`, `bitmap pushTab`, `bitmap back from=...`;
- dropped frames в `animate` должны резко снизиться, потому что SwiftUI rows/context menus/icons больше не двигаются;
- возможная стоимость может остаться в `snapshot` или `live-mount`, но она должна быть до/после видимого slide и скрыта frozen bitmap'ом;
- если `bitmap ... unavailable -> SwiftUI fallback`, значит снимок/рендер не получился, и лог надо читать как старую архитектуру.

### 9. Итерация 21:56-21:59: bitmap path активен, но SwiftUI overlay всё ещё даёт jank

После установки bitmap transition layer новые логи подтвердили, что код реально пошёл по новому пути:

```text
21:56:54.133 frame monitor armed ... label="bitmap pushProject name=hh-tool"
21:56:54.915 frame ... label="bitmap pushProject name=hh-tool" dropped=7 worst=82ms byPhase[animate=4/81ms settle=3/70ms]
21:56:56.123 frame ... label="bitmap back from=tabs" dropped=13 worst=76ms byPhase[animate=9/39ms settle=4/75ms]
21:56:57.210 frame ... label="bitmap pushProject name=custom-terminal" dropped=5 worst=94ms byPhase[settle=5/93ms]
21:57:00.236 frame ... label="bitmap pushTab ..." dropped=6 worst=63ms byPhase[animate=3/44ms settle=3/62ms]
```

Вывод:

- bitmap path работает, fallback не случился;
- network/history уже заметно лучше изолированы: `activation quiet` запускает history после nav window, а не в середине push;
- но сама реализация `TerminalBitmapTransitionView` через SwiftUI `Image(uiImage:)` + `.offset` всё ещё может дропать кадры в `animate`;
- значит это ещё не настоящий UIKit/CALayer compositor-only transition. Мы перестали двигать списки, но всё ещё двигаем полноэкранные bitmap view внутри SwiftUI transaction.

Отдельный UX-баг из этих же логов:

- после визуального завершения back/push первый тап по списку мог не срабатывать;
- причина была локальная: после commit мы держали frozen bitmap destination ещё `snapshotOverlayHoldMs=260ms`, и live content был `.allowsHitTesting(false)`, пока `terminalBitmapTransition != nil`;
- визуально пользователь уже видел нужный экран, но настоящий live список под overlay ещё не принимал touch.

Фикс после логов 21:56:

- разделены `bitmap motion` и `bitmap hold`;
- live content снова принимает hit-testing в `.hold`, overlay остаётся `allowsHitTesting(false)`;
- bitmap-анимации ускорены и переведены с `easeOut` на короткую linear-кривую:
  - push: `0.14s`;
  - back: `0.13s`.

Ожидание от версии 21:59:

- первый тап после завершения движения должен проходить сразу, не ждать hold-tail;
- "вяло в начале, потом ускоряется" должно стать меньше из-за linear-кривой;
- если `byPhase[animate]` всё ещё показывает `worst > 50ms`, ускорение duration не решит root cause: следующий шаг именно UIKit `UIImageView` / `UIViewPropertyAnimator` / `CALayer.transform`, чтобы SwiftUI вообще не участвовал в движении bitmap surfaces.

### 10. Итерация 22:03-22:07: SwiftUI bitmap overlay заменён на UIKit `UIImageView`

Логи после версии 21:59 показали, что duration/linear-кривая не закрыли проблему:

```text
22:03:27.277 bitmap pushProject custom-terminal dropped=6 worst=71ms byPhase[animate=3/70ms settle=3/63ms]
22:03:28.250 bitmap pushProject hh-tool dropped=8 worst=73ms byPhase[animate=5/41ms settle=3/72ms]
22:03:29.627 bitmap pushProject mac-electron dropped=6 worst=73ms byPhase[animate=2/41ms settle=4/72ms]
22:03:31.206 bitmap pushProject custom-terminal done dropped=14 worst=104ms byPhase[animate=5/25ms settle=9/103ms]
```

Вывод:

- `bitmap` labels подтверждают, что value-list SwiftUI preview уже не ехал;
- но `animate` всё ещё получал плохие кадры, значит SwiftUI `TerminalBitmapTransitionView` с `Image(uiImage:)` и `.offset` сам оставался слишком дорогим moving layer;
- `settle=103ms` на `done` после commit указывает на отдельный live-mount cost выбранной tabs page под overlay.

Фикс после логов 22:03:

- `TerminalBitmapTransitionView` заменён на `TerminalBitmapTransitionOverlay` (`UIViewRepresentable`);
- внутри него `TerminalBitmapTransitionHostView` держит два `UIImageView` (`source`/`destination`) и `CAGradientLayer` edge shade;
- движение bitmap surfaces теперь делается через UIKit `UIView.animate` + `CGAffineTransform`, а не через SwiftUI `withAnimation` / `.offset`;
- SwiftUI state во время animation не меняет per-frame offset; он только монтирует overlay и коммитит финальный state после completion;
- интерактивный drag всё ещё обновляет offset через state, но обновляется только lightweight `UIViewRepresentable`, не SwiftUI `Image` tree.

Ожидание от версии 22:07:

- `byPhase[animate]` у `bitmap pushProject/back` должен стать существенно чище;
- если плохим останется в основном `settle/live-mount`, следующий фокус - облегчать live tabs/projects mount после commit и/или дольше держать frozen bitmap, но не блокировать hit-testing;
- если `animate` всё ещё плохой, значит проблема уже ниже уровня SwiftUI bitmap view: возможно window snapshot/render/capture, root pager/bar animation, или системный compositor под full-screen images.

### 11. Итерация 22:09-22:13: UIKit overlay был быстрым, но стартовал race-ом

После версии 22:07 субъективно всё стало очень быстрым, но визуально неправильным:

- forward `projects -> tabs` выглядел почти мгновенным, без нормального slide;
- back `tabs -> projects` сначала двигал текущий project tabs surface, а не projects destination, затем происходил резкий jump на список проектов;
- похожий визуальный баг проявлялся на `chat -> tabs`.

Логи объяснили это:

```text
22:09:56.511 monitor armed ... bitmap pushProject custom-terminal phase=snapshot
22:09:56.550 TerminalNav select project ... phase=live-mount age=38ms
22:09:58.329 monitor armed ... bitmap pushProject hh-tool phase=snapshot
22:09:58.338 TerminalNav select project ... phase=live-mount age=9ms
```

То есть commit происходил через `9-38ms`, раньше видимой `0.14s` анимации. Причина:

- `TerminalBitmapTransitionOverlay` был условным SwiftUI subtree (`if let terminalBitmapTransition`);
- после `terminalBitmapTransition = ...` SwiftUI ещё не всегда успевал создать `UIViewRepresentable` и вернуть `TerminalBitmapTransitionHostView`;
- `animateTerminalBitmap` видел `terminalBitmapOverlayView == nil` и делал direct-commit fallback;
- результат: быстро, но без корректного forward slide; back мог стартовать со stale/неподготовленной bitmap surface.

Фикс после логов 22:09:

- `TerminalBitmapTransitionOverlay` теперь постоянно смонтирован в Terminal content layer, а не создаётся только на время перехода;
- host умеет `state == nil`: скрывается, чистит images/layer animations и не участвует в hit-testing;
- перед `UIView.animate` код явно вызывает `overlay.configure(currentState)`, чтобы source/destination были актуальны синхронно;
- `waitForBitmapOverlay()` ждёт не только наличие view, но и ненулевые bounds;
- добавлен диагностический лог `bitmap overlay not ready — direct commit fallback`. Если он появится, значит опять был fallback и визуальный jump ожидаем.

Ожидание от версии 22:13:

- forward slide должен снова быть видимым, а не мгновенным;
- back destination должен быть правильным (`projects` при `tabs -> projects`, tabs list при `chat -> tabs`);
- если визуальный jump исчез, дальше можно оценивать только frame metrics; если jump останется и при этом fallback-лога нет, значит bug уже в выборе cached destination bitmap, а не в readiness overlay.

### 12. Итерация 22:13-22:54: bitmap path отключён, переход на постоянные layers

Проверка после 22:13 показала, что bitmap/UIView path стал быстрым, но визуально неправильным:

- `projects -> tabs` мог выглядеть как мгновенная телепортация без нормального slide;
- при `tabs -> projects` во время back-drag часто не было правильного preview списка проектов;
- иногда ехал тот же экран поверх самого себя, а после отпускания происходил резкий jump;
- быстрые клики после back всё ещё могли попадать в хвост transition/overlay;
- scroll списков проектов/вкладок продолжал сбрасываться или прыгать после reload/state update.

Главный вывод: bitmap-подход был правильным как направление "не двигать тяжёлый SwiftUI список", но конкретная гибридная реализация стала слишком хрупкой. Она держала отдельные frozen images, live SwiftUI content и store selection в разных фазах. При быстром push/back они легко расходились: пользователь уже видел один слой, store уже выбрал другой, а cached bitmap мог соответствовать третьему состоянию.

Поэтому bitmap transitions временно отключены:

```swift
private let terminalBitmapTransitionsEnabled = false
```

Для этой конкретной итерации 22:54: если в логах снова появились labels вида
`bitmap pushProject`, `bitmap back from=tabs` или phase `bitmap-preflight`, это означало
старую сборку или случайно включённый global bitmap flag. Позже, после 00:20, bitmap path
был включён обратно узко для `projects <-> tabs`; см. раздел "targeted real bitmap snapshot"
ниже.

Новый архитектурный шаг после этого:

- Terminal content больше не выбирает один экран через условную схему "если выбран tab - chat, иначе если выбран project - tabs, иначе projects";
- внутри root Terminal content теперь постоянно живут три слоя:
  - `projects`;
  - `tabs`;
  - `chat`;
- слои лежат в одном `ZStack` и просто сдвигаются по X;
- `projects` и `tabs` больше не размонтируются при каждом переходе назад/вперёд;
- local state `persistentProject` / `persistentTab` хранит последний выбранный project/tab, чтобы слой tabs/chat мог остаться живым даже когда store уже сделал шаг назад;
- store selection остаётся источником правды для API/SSE/history, а persistent state нужен только для жизни view и сохранения scroll;
- обычный `pushProject/back from=tabs` больше не должен иметь фазу `live-mount`: экран уже смонтирован, transition только двигает layers.

Логи, которые теперь важны после версии 22:54:

```text
pushProject ... label="term-nav pushProject ..."
back from=tabs ... label="term-nav back from=tabs"
```

Без слова `bitmap`.

Нормальный ожидаемый профиль:

- `TerminalNav select project ... phase=swap`, а не `phase=live-mount`;
- `[TerminalScroll] projects anchor click ...` при клике по проекту;
- `[TerminalScroll] tabs anchor click ...` при клике по вкладке;
- при back scroll проектов/вкладок должен сохраняться, потому что соответствующий `ScrollView` больше не создаётся заново;
- если `/tabs` reload приходит после transition и `changed=false` или меняются только status/session fields, он не должен пересоздавать список и сбрасывать scroll.

Ограничение этого шага:

- chat detail всё ещё частично привязан к active selected tab, потому что history/SSE/composer нельзя держать полноценно активными для невидимого tab;
- старый snapshot/bitmap code пока оставлен как fallback/dead code, но нормальный путь его не использует;
- если после постоянных layers останутся `worst=60-90ms`, это уже не "размонтировали список проектов на back", а стоимость живого layer/compositor/header/bar/state writes.

### 13. Проверка 22:56: persistent layers включились, но row churn остался

Новый trace после версии 22:54:

```text
22:56:05.792 [TerminalScroll] projects anchor click id=cm1pbmFs
22:56:06.098 [TerminalNav] select project ... phase=swap
22:56:06.847 [frame] pushProject ... dropped=14 worst=87ms byPhase[animate=5/25ms mount=3/65ms settle=6/86ms]
22:56:07.531 [term-render] row bodies=18 distinct=17 ... nav=nav#4 phase=settle
22:56:08.076 [frame] back from=tabs ... dropped=14 worst=85ms byPhase[animate=8/29ms settle=6/85ms]
```

Что это доказывает:

- новая архитектура реально активна: нет `bitmap ...`, есть `projects anchor click`, commit идёт через `phase=swap`, не через `live-mount`;
- значит проблема уже не в пересоздании уровня `projects/tabs` как таковом;
- `[term-render] row bodies=18` во время `back from=tabs` `settle` показывает, что live rows вкладок всё ещё пересобираются в хвосте перехода;
- причина текущего лага ближе к тому, что transition state в родителе трогает весь `ZStack`, а heavy row controls/animations возвращались слишком рано.

Фикс после 22:56:

- `heavySurfaceResumeDelayMs` увеличен до `1500ms`, чтобы animated rows/context menus/refresh/FAB возвращались уже после frame-monitor settle window;
- сами row buttons остаются интерактивными: delayed только тяжёлый visual/control слой;
- project activity badge на карточках проектов сделан статичным (`animatedBadge=false`), потому что live ring мог выглядеть слишком быстрым и добавлял постоянную row-анимацию.

Ожидание от следующей проверки:

- в `settle` после `back from=tabs` не должно быть `term-render row bodies=18`;
- loader/activity badge на project cards больше не должен бешено вращаться;
- если frame drops останутся без row churn, следующий источник - compositor/layout самих persistent layers или root header/bar updates.

### 14. Итерация 23:26-23:31: skeleton rows доказали root cause

После нескольких проверок persistent layers всё ещё давали лаги на тяжёлом проекте
`custom-terminal`:

```text
23:26:25.242 pushProject custom-terminal
23:26:25.530 select project ... cachedTabs=true fresh=true tabCount=17
23:26:25.530 skip tabs reload (cache fresh)
23:26:25.799 frame ... pushProject ... dropped=11 worst=77ms byPhase[animate=4/25ms mount=2/44ms settle=5/76ms]
23:26:26.999 frame ... back from=tabs ... dropped=9 worst=62ms byPhase[animate=2/25ms settle=7/61ms]
```

Ключевой факт: `cachedTabs=true fresh=true` и `skip tabs reload`, но `worst=77ms`.
Значит это не API, не cache miss и не `/tabs` response, а локальная стоимость показа
tabs surface.

Проверочный фикс:

- во время `pushProject` и `back from=tabs/chat` moving tabs layer больше не строит
  настоящий `TerminalProjectTabsView`;
- вместо живого списка показывается статичный `TerminalTabsSkeletonList`;
- `backPreviewSnapshot` и `transitionSourceSnapshot`, которые раньше частично
  не использовались в persistent-layer path, подключены прямо в `terminalPersistentLayer`;
- skeleton rows не читают store, не имеют `ScrollView`, `contextMenu`, loader, agent
  icon asset lookup, gestures, `.scrollPosition` и per-row hit-testing;
- настоящий live tabs screen включается после commit/settle.

Результат по логу 23:31:

```text
23:31:38.464 pushProject custom-terminal
23:31:38.747 select project ... cachedTabs=true fresh=true tabCount=17
23:31:38.747 skip tabs reload (cache fresh)
23:31:39.097 frame ... pushProject ... dropped=5 worst=91ms byPhase[settle=5/91ms]
23:31:40.300 frame ... back from=tabs ... dropped=13 worst=89ms byPhase[animate=7/27ms gesture=1/39ms settle=5/89ms]
```

Субъективный результат пользователя: "теперь лага нет", а анимация стала быстрой как
надо. Это важнее сырых `settle=91ms`: видимый slide стал лёгким, а тяжёлая работа
сместилась в хвост, где пользователь уже видит завершённый переход. Однако серый
skeleton визуально нежелателен.

Вывод:

- проблема не в том, что "iPhone 15 Pro не тянет 17 карточек";
- проблема в том, что наш custom SwiftUI container пытался сделать live-mount /
  live-commit 17 interaction-heavy rows в те же кадры, где двигается horizontal layer;
- 17 rows сами по себе нормальны, если они уже mounted или если во время motion
  показывается дешёвая visual-only поверхность;
- grey skeleton - диагностический и временный фикс, а не финальное UX-решение.

External research через ChatGPT 5.5 xhigh подтвердил этот диагноз:

- Apple-совместимая трактовка: это architecture-triggered SwiftUI frame-budget
  problem, а не network/cache и не обязательно Apple bug;
- Apple guidance: measure -> identify update cause -> reduce work in transition ->
  remeasure; bodies/layout/commit должны уложиться в frame deadline;
- SwiftUI может показать этот UI, но плохо переносит ситуацию, где новая сложная
  subtree создаётся/обновляется/коммитится в те же кадры, где идёт custom transition;
- skeleton доказывает не "skeleton обязателен", а "moving live subtree слишком дорогая";
- лучший SwiftUI-first путь: persistent mounted levels + rows не читают nav progress /
  broad store + visual-only rows during motion + deferred controls after settle;
- лучший вариант без grey skeleton: full-content static proxy - реальные title/path/icon/status
  из cached data, но без live controls, contextMenu, animated loader, scroll tracking и
  broad store reads до окончания transition;
- UIKit/UICollectionView container transition остаётся самым высоким ceiling, если нужна
  Instagram-grade интерактивность без proxy, но это уже отдельная архитектурная работа.

Следующий рациональный шаг после skeleton-теста:

1. Заменить grey skeleton на real-content static proxy:
   - реальные названия вкладок;
   - реальные paths;
   - реальный agent icon или дешёвый predecoded/static icon;
   - реальная status color dot;
   - фиксированная высота строки;
   - без `contextMenu`, `refreshable`, `ProgressView`/loader animation, `.scrollPosition`,
     row gestures и store reads во время transition.
2. Если такой proxy сохраняет плавность, оставить его как финальный transition surface.
3. Если proxy снова даёт `animate > 50ms`, значит даже визуальные full rows слишком дороги
   в SwiftUI transition; тогда выбор между:
   - мгновенным переходом без slide;
   - настоящим UIKit container / UICollectionView transition;
   - оставить grey/abstract placeholder.

## Что было проверено и не решило проблему полностью

### "Это просто сеть"

Нет. Network часто усиливал лаг, но frame drops оставались и при cached/fresh tabs:

```text
select project cachedTabs=true fresh=true
skip tabs reload (cache fresh)
pushProject ... dropped/worst still present
```

Значит основной render jank не объясняется только HTTP.

### "Достаточно отложить /tabs reload"

Нет. Deferred reload убрал часть mid-settle writes, но `pushProject` с fresh cache всё равно лагал.

### "Достаточно snapshot destination"

Нет. Source layer тоже оставался live и мог пересобираться. После frozen source стало лучше в отдельных кейсах, но не полностью.

### "Header исчезал из-за NavigationStack toolbar"

Не основной root cause. Системный nav bar был скрыт, но кастомный header исчезал потому, что жил внутри transient subtree и зависел от snapshot/overlay conditions.

### "Иконки приходят по API"

Нет. По API приходит только agent metadata. Картинки локальные. Пропадание было из-за inconsistent agent detection и отдельного preview row implementation.

### "Достаточно bitmap/UIView snapshot поверх SwiftUI"

Нет в той реализации, которая была проверена. Она действительно убрала часть live-list work из slide и субъективно местами стала быстрее, но дала более опасные UX-баги:

- forward мог телепортировать экран без видимого slide;
- back мог показывать не тот preview;
- один и тот же tabs screen мог ехать поверх самого себя;
- live content, store selection и cached bitmap расходились при быстрых действиях.

Поэтому bitmap path сейчас выключен. Возвращаться к нему имеет смысл только как к полноценному UIKit container transition, где весь стек владения экраном и gesture живёт в одном месте, а не как overlay поверх условного SwiftUI subtree.

### "Skeleton значит финально надо показывать skeleton"

Нет. Skeleton доказал root cause, но не является единственным UX-решением.
Он просто убрал live-list work из кадра движения. Более подходящая финальная версия
для Terminal - real-content static proxy: пользователь видит настоящие вкладки сразу,
но это не живые SwiftUI rows с меню, loader'ами, scroll tracking и store reads.

## Текущие открытые проблемы

### 1. Остаточный project navigation jank

До постоянных layers последние логи всё ещё показывали:

```text
pushProject ... worst=48-65ms
back from=tabs ... worst=49-73ms
```

Bitmap path был проверен и отключён из-за визуальных race-ов. Текущий активный вариант - постоянный трёхслойный контейнер `projects/tabs/chat`, где levels не размонтируются при переходах.

Что надо проверить новыми логами после версии 22:54:

- исчезли ли `phase=live-mount` у обычных `pushProject/back from=tabs`;
- сохраняется ли scroll на `projects` и `tabs` после back;
- нет ли `bitmap ...` labels, иначе тестируется старая сборка/старый path;
- ушли ли `settle=70-100ms` при быстрых back/push;
- проходит ли первый tap/scroll сразу после визуального окончания transition.

После skeleton-теста 23:31 главный видимый slide стал быстрым, но frame logs всё ещё
показывают плохой `settle`:

```text
pushProject ... dropped=5 worst=91ms byPhase[settle=5/91ms]
back from=tabs ... dropped=13 worst=89ms byPhase[animate=7/27ms gesture=1/39ms settle=5/89ms]
```

Это читается так:

- moving live list больше не является видимой причиной лага;
- настоящий live tabs screen всё ещё включается в хвосте перехода и может давать
  `settle=80-90ms`;
- пользователь субъективно уже не видит основной лаг, но серый skeleton заметен и
  нежелателен.

Текущий next step: заменить grey skeleton на real-content static proxy. Это должно
сохранить быстрый transition и убрать ощущение "пустых скелетонов".

### 2. Первый open Terminal из drawer

Логи вида:

```text
chat-drawer drag surface=chat ... dropped=3 worst=69ms
chat-drawer close surface=terminal ... dropped=2-5 worst=50-94ms
```

Что уже было сделано:

- Terminal surface swap ждёт drawer-open перед close;
- explicit `terminal.start()` убран из close action;
- cache warm/start skip логируется.

Что осталось:

- drawer animation всё ещё может лагать при переключении Voice Chat <-> Terminal;
- вероятные факторы: composer activation/inactivation, keyboard/base inset, surface mount, terminal root first render;
- это отдельная проблема от `term-nav`.

Новая интерпретация по 21:41: во время первого входа Terminal прямой tap по строке drawer не логируется, поэтому "длина клика" не видна. Видны косвенные события `TerminalCache start warm cache`, `composer inactive`, `close surface=terminal`. Для точного tap latency нужен отдельный лог pointer/tap в строке Terminal drawer; пока это не добавлено.

### 3. Terminal chat scroll blank/overscroll

Сильный диагностический факт:

```text
dContent=-846
old off=6103 content=6954 dist=136 ratio=0.98
new off=6103 content=6108 dist=-710 ratio=1.13
```

Значит content height может резко уменьшиться, а offset не clamp-ится. `followBottom=true` при этом может быть ложным состоянием: мы считаем, что у bottom, но geometry уже вне валидного диапазона.

Следующие варианты:

- при `distFromBottom < -threshold` принудительно scrollTo bottom без animation;
- разделить user-driven scroll intent и geometry correction;
- пересмотреть `.defaultScrollAnchor(.bottom)` + `LazyVStack` + dynamic text height;
- логировать entry ids/heights или хотя бы `entries.count`, `tail text count`, `contentHeight delta` вместе с причиной update.

Статус после итерации 21:15-21:41: добавлен overscroll clamp/re-pin по отрицательному `distFromBottom`. Это не закрывает всю scroll-memory проблему списков проектов/вкладок.

Статус после версии 22:54: scroll-memory проектов/вкладок теперь должен решаться не bitmap preview, а тем, что сами `ScrollView` levels остаются смонтированными. Дополнительно `scrollPosition(id:)` не сбрасывается на `nil`, а при клике по проекту/вкладке явно сохраняется текущий anchor.

### 4. PushTab settle

Даже с history publish parking:

```text
pushTab ... dropped=4 worst=81-83ms byPhase[settle=4/81ms]
history publish park / done near nav tail
```

Вероятный источник:

- live `TerminalChatDetailView` mount: ScrollView + LazyVStack + composer + floating controls;
- geometry/scroll metrics fire immediately;
- history assignment может происходить сразу после nav window.

Следующие варианты:

- при pushTab дольше держать placeholder/snapshot, пока live chat detail стабилизируется;
- lazy-load composer/floating controls после transition;
- не стартовать history load до окончания visible transition, либо publish только after `FrameMonitor` done.

## Правила чтения будущих логов

1. Сначала смотреть `[frame]`.
   Если `dropped=0-2` и `worst < 35ms`, пользовательский лаг маловероятен. Если `worst > 50ms`, это реальный фриз.

2. Не смотреть только `animate`.
   `settle=80ms` тоже видимый лаг, особенно если пользователь быстро делает следующий gesture.

3. Сравнивать `TerminalHTTP response/load done` с `nav phase`.
   Response в `phase=settle` может быть вреден даже при `changed=false`.

4. Если `cachedTabs=true fresh=true` и `skip tabs reload`, но jank есть, искать UI/render, не сеть.

5. Если `term-render row bodies` высокий, искать observable writes / body churn.
   Если `term-render` низкий, но `[frame]` плохой, искать compositor/layout/material/shadow/snapshot cost.

6. Для scroll-багов смотреть `dContent`, `dOff`, `dist`, `ratio`.
   `ratio > 1` или большой отрицательный `dist` означает invalid offset после изменения content size.

7. `tool=-` в SSE snapshot не должен ломать иконки.
   Тип агента должен сохраняться из tab metadata/session/color/name.

## Текущее состояние кода после этой сессии

Изменённые основные файлы:

- `TerminalControlUI.swift`
  - root persistent terminal header;
  - `showsHeader: false` для child/snapshot views;
  - постоянные layers `projects`, `tabs`, `chat` в одном root `ZStack`;
  - `persistentProject` / `persistentTab` удерживают последние выбранные inputs для tabs/chat layers;
  - back/push двигают layer offsets, а не пересоздают весь Terminal content;
  - старые forward/back snapshots и bitmap code оставлены как fallback/dead code, но нормальный path их не использует;
  - placeholder для chat push;
  - preview rows теперь используют `AgentIconView`;
  - real clickable suspended lists instead of non-interactive preview rows;
  - store-owned `.scrollPosition(id:)` для projects/tabs;
  - nil scroll anchors игнорируются, чтобы geometry/update не сбрасывал позицию в начало;
  - явный save scroll anchor при клике по project/tab;
  - во время `pushProject/back` moving tabs layer временно показывает `TerminalTabsSkeletonList`;
  - после 23:31 это рассматривается как диагностический фикс, который надо заменить
    на real-content static proxy;
  - временные кнопки в terminal header: copy all chat logs с количеством строк и clear logs.

- `TerminalControlStore.swift`
  - deferred tabs reload;
  - longer quiet windows for prefetch/history publish;
  - activation quiet window before Terminal tab history/params/status/SSE startup;
  - loadTabs in-flight dedupe;
  - normalized agent type detection;
  - safer status/SSE tool/session updates;
  - visible tabs publish меньше трогает список, если изменились только status/session поля, а порядок/id вкладок не поменялись;
  - store-owned scroll anchors for projects/tabs.

- `VoiceChat.swift` / `VoiceChatStore.swift`
  - `developerMode` включён в config defaults;
  - `VCLog.lineCount()` для быстрых debug-кнопок.

- `VoiceChatUI.swift`
  - drawer surface swap waits for drawer-open;
  - removed direct duplicate terminal start from drawer close path;
  - changed terminal open/close sequencing;
  - root pager lock while `terminalMode && terminal.canStepBack` to prevent black overscroll leak;
  - Developer mode toggle добавлен в AI Chat settings diagnostics.

Последняя проверенная установка:

- 21:07 - версия с root header + frozen source snapshot была установлена.
- 21:14:58 - версия с исправлением Claude/Codex icons была установлена.
- 21:54 - версия с bitmap transition layer + root pager lock была собрана и установлена на iPhone; её надо проверять по новым `bitmap ...` frame labels.
- 21:59 - версия с linear bitmap animation (`0.14s/0.13s`) и исправленным hit-testing во время bitmap hold установлена на iPhone.
- 22:07 - версия с UIKit `UIImageView` bitmap overlay вместо SwiftUI bitmap moving view установлена на iPhone.
- 22:13 - версия с persistent UIKit overlay host и защитой от early direct-commit fallback установлена на iPhone.
- 22:54 - версия с отключённым bitmap path и постоянными `projects/tabs/chat` layers установлена на iPhone. Новые логи должны быть без `bitmap ...` labels.
- 23:31 - версия со skeleton transition surface для tabs layer установлена на iPhone.
  Пользователь подтвердил, что видимого лага теперь нет, но skeleton визуально нежелателен.

## Итог расследования

На данный момент доказано:

- header disappearing был архитектурным багом snapshot/header ownership, а не сетью;
- часть jank шла от network/state writes в хвосте навигации;
- часть jank шла от live SwiftUI source/destination views во время slide;
- frozen source/destination и deferred publishes помогли, но не убрали быстрый `projects <-> tabs` jank;
- bitmap/UIView overlay был проверен как более жёсткий подход: он частично ускорял ощущения, но дал визуальные race-ы и был отключён;
- текущий активный подход - постоянный контейнер с тремя живыми layers `projects/tabs/chat`, чтобы back не пересоздавал страницы и не сбрасывал scroll;
- skeleton transition surface доказал, что root cause остаточного `custom-terminal`
  лага - live tabs rows/controls во время motion/settle, а не количество данных и не API;
- skeleton не должен считаться финальным UX; финальный SwiftUI-first next step -
  real-content static proxy с настоящими текстами/иконками/status, но без live controls
  до окончания transition;
- scroll blank связан с резким изменением content height без clamp offset;
- scroll-memory projects/tabs теперь должна держаться за счёт постоянных layers и store-owned scroll anchors;
- Claude/Codex icons локальные, а их "мигание" было из-за inconsistent tool detection и отдельной lightweight preview row реализации.

Следующий рациональный шаг после версии 23:31 - заменить grey skeleton на real-content
static proxy и сравнить логи. Нормальный trace должен сохранить быстрый субъективный slide,
но визуально показывать настоящие вкладки сразу. Если `animate` снова станет `>50ms`, значит
даже full-content SwiftUI proxy дорог для motion, и тогда остаются мгновенный переход или
полноценный UIKit container transition.

## Продолжение 00:06-00:20: scroll reset и отказ от точечных restore-fixes

После real-content/lightweight rows лаги стали заметно меньше, но всплыл другой класс
проблем: вертикальный scroll мог сбрасываться не только после API refresh, но и прямо в
момент клика по проекту, пока экран ещё уезжает влево. Логи вокруг `00:12-00:18` показали,
что явного `projects restore` уже нет, а jump всё равно иногда происходит. Значит проблема
не сводится к одной строке `scrollTo`: live `ScrollView` проектов всё ещё остаётся частью
движущейся SwiftUI-композиции и может переякориться/перелэйаутиться во время ухода.

Отдельно обнаружен опасный дефолт для tabs-scroll: если сохранённого anchor ещё нет,
`restoreTabsScrollIfNeeded` выбирал `rowIds[0]` и делал `proxy.scrollTo(... .top)`. Это
маскировалось как "восстановление", но фактически могло само поднимать список вкладок в
начало после первого mount/update. Такой restore без сохранённого anchor нельзя делать:
если нет памяти позиции, список должен просто остаться в естественном положении, а не
получать программную команду scroll-to-top.

Вывод по этой ветке: дальше править только store-owned anchors бессмысленно. Когда экран
должен уехать, а его scroll position обязан визуально остаться ровно тем, что видел
пользователь при клике, moving source должен быть не live SwiftUI `ScrollView`, а реальный
bitmap snapshot текущего UIView. Тогда любые поздние SwiftUI/layout/API изменения происходят
под неподвижной картинкой и не могут визуально сбросить уходящий список.

## Reddit / external research summary

Внешний ресёрч и Reddit-треды сошлись с практическими логами:

- SwiftUI `ScrollView`/`TabView` может терять scroll state, если контейнер пересоздаётся
  или получает широкий state update.
- Programmatic `scrollTo`/`scrollPosition` легко становится причиной jump, если используется
  как "restore" не строго по сохранённому пользовательскому anchor.
- Для сложных custom transitions рабочий паттерн - двигать дешёвую стабильную поверхность:
  persistent mounted views, static proxy, bitmap snapshot или UIKit container.
- `List`/`UICollectionView` могут дать лучший потолок, но не являются автоматическим фиксом,
  если проблема в том, что live дерево активируется в кадры перехода.

## Версия после 00:20: targeted real bitmap snapshot

Принято решение не возвращать старый global bitmap path целиком. Он уже проверялся в
22:24-22:36 и дал визуальные гонки: old screen twitch, teleport, missing back preview, same
page sliding over itself. Новый вариант уже:

- bitmap включён только для границы `projects -> tabs` и `tabs -> projects`;
- `chat -> tabs` и `tabs -> chat` остаются на текущем SwiftUI path;
- source bitmap для `pushProject` берётся только из текущего live UIView через
  `captureCurrentTerminalBitmap`, без fallback на value preview, чтобы сохранить реальный
  scroll offset проектов;
- для `back from=tabs` destination projects берётся из `cachedProjectsBitmap`, captured при
  входе в проект; если bitmap cache отсутствует, код откатывается на SwiftUI path;
- после commit bitmap hold увеличен до 220ms, чтобы live SwiftUI мог подмонтироваться за
  картинкой;
- `restoreTabsScrollIfNeeded` больше не скроллит к первой вкладке, если сохранённого anchor
  нет.

Ожидаемые новые логи:

```text
[frame] ... label="bitmap pushProject ..."
[frame] ... label="bitmap back from=tabs"
```

Если визуальный jump проектов исчезнет, значит root cause был именно live source ScrollView
во время ухода. Если bitmap labels есть, но остаются `worst=70-90ms`, надо смотреть, видит ли
пользователь этот hitch под overlay. Если видит - следующий шаг уже не SwiftUI refactor, а
UIKit container / UICollectionView boundary для `projects/tabs`.

## 00:29: targeted bitmap снова отклонён

Проверка версии с targeted bitmap показала, что старые визуальные баги всё ещё живы:

```text
label="bitmap pushProject name=custom-terminal"
label="bitmap back from=tabs"
```

Субъективно:

- при `tabs -> projects` preview появлялся не сразу или был не тем экраном;
- иногда текущий project-tabs экран мелькал поверх себя;
- после отпускания происходил резкий визуальный swap;
- scroll projects то восстанавливался, то нет.

Вывод: проблема не только в том, какие картинки брать. В текущем SwiftUI root container
bitmap overlay, live layers, cached images и `store.selectedProject` всё ещё имеют разные
фазы жизни. Без настоящего UIKit-owned container transition этот bitmap path остаётся
хрупким. Поэтому targeted bitmap снова выключен.

Stop-loss решение после 00:29:

- `terminalBitmapProjectTransitionsEnabled = false`;
- `projects -> tabs` сделан instant transition без slide-анимации;
- цель - убрать визуальный сброс source ScrollView при клике по project, даже ценой
  отсутствия красивого push-slide;
- если back-свайп `tabs -> projects` останется нестабильным, его надо переводить в такой же
  instant back или делать полноценный UIKit container, а не чинить bitmap overlay.

## 00:33: scroll reset через секунду после back

После instant `projects -> tabs` остался отдельный баг: пользователь возвращается на projects,
начинает скроллить в первую секунду, а потом scroll сбрасывается. По архитектуре это уже не
навигационный slide. Причина в том, что `renderSuspended` менял структуру списков после
transition tail:

- projects/tabs list сначала рендерился без full controls;
- через `heavySurfaceResumeDelayMs` включались context menu / refresh / animated rows;
- у tabs list менялся даже тип row view: `TerminalTabPreviewRow` -> `TerminalTabRow`;
- SwiftUI мог воспринять это как пересборку scroll content/container и сбросить offset.

Фикс: форма списков должна быть стабильной всегда. `renderSuspended` больше не снимает
context menu / refresh и больше не меняет тип row. Он только выключает live animation loader
через параметр `animated`, оставляя тот же row view и тот же ScrollView.

## 00:37-00:40: большой лог `111.md` и текущий вывод

Файл `/Users/fedor/Downloads/111.md` показал, что после stop-loss версии `projects -> tabs`
действительно стал instant:

```text
[term-swipe] pushProject custom-terminal — instant project boundary
[TerminalNav] select project ... cachedTabs=true fresh=true ...
[TerminalNav] skip tabs reload (cache fresh)
```

Это убирает главный визуальный jump при уходе со страницы проектов, но не решает саму
архитектурную проблему:

- `tabs -> projects` всё ещё идёт через live SwiftUI horizontal back animation;
- `back from=tabs` стабильно даёт хвостовые dropped frames, обычно `worst=65-90ms`;
- часть новых `pushProject` происходит, пока предыдущий `back from=tabs` ещё в `settle`;
- в логах projects-scroll есть только `projects anchor idle id=...`, но нет настоящего
  `projects restore`;
- значит сохранение scroll projects сейчас зависит от того, сохранил ли SwiftUI живой
  экземпляр `ScrollView`, а не от нашего детерминированного restore.

Именно поэтому пользовательский симптом выглядит рандомно: "то сбросился, то нет". Если
SwiftUI сохранил live `ScrollView` - позиция осталась. Если SwiftUI пересоздал/перелэйаутил
контейнер из-за смены selection, back tail, refresh или structural update - позиция прыгнула.

Важный факт: по этим логам API не является главным триггером. В нескольких проблемных местах
видно `fresh=true` и `skip tabs reload`, то есть scroll/jank может происходить без полезного
сетевого publish. Network writes уже загейтированы лучше, чем раньше; оставшаяся проблема -
именно ownership scroll/navigation.

## Reddit/social research: что подтверждено обсуждениями

Через Reddit MCP были просмотрены похожие треды:

- `SwiftUI ScrollView jumping to top when loading new data`;
- `NavigationView go back when updating object in ViewModel`;
- `SwiftUI in production`;
- `Why you should start with UIKit for your new app`.

Полезные ссылки:

- https://www.reddit.com/r/SwiftUI/comments/1jw39ry/how_to_prevent_scrollview_from_jumping_to_the_top/
- https://www.reddit.com/r/SwiftUI/comments/vd7uer/why_navigationview_go_back_when_updating_object/
- https://www.reddit.com/r/iOSProgramming/comments/1sdumb7/why_you_should_start_with_uikit_for_your_new_app/
- https://www.reddit.com/r/iOSProgramming/comments/1mgg4aw/swiftui_in_production_what_actually_worked_and/

Сводка не как финальная истина, а как совпадающий с нашими логами практический опыт:

- Scroll сбрасывается, когда пересоздаётся/инвалидируется сам scroll container, а не только
  меняются строки внутри него.
- Programmatic `scrollTo`/`scrollPosition` легко превращается в причину jump, если restore
  вызывается не строго после сохранённого пользовательского anchor и не в правильной фазе.
- Широкий observable state, который читает весь экран/список, может инвалидировать слишком
  много view сразу.
- Для сложных мест люди часто оставляют SwiftUI для оболочки, но уходят в UIKit там, где
  нужны точный scroll offset, custom gesture, collection/list reuse и управляемый transition.
- `List` или `LazyVStack` сами по себе не являются гарантированным фиксом, если root cause -
  live SwiftUI tree во время interactive transition.

## Текущее решение и следующий нормальный шаг

Текущая рабочая версия - компромиссная:

- `projects -> tabs` instant, без slide;
- targeted bitmap project transition выключен из-за визуальных гонок;
- row/list структура стабилизирована: `renderSuspended` больше не меняет тип row и не снимает
  controls;
- network reload/prefetch в основном не публикуется во время active interaction.

Но требование пользователя на следующую сессию другое: нужен полноценный back gesture, где при
ведении пальцем страница движется "как книжка", и при этом scroll не прыгает. Для этого дальше
не стоит продолжать точечно чинить SwiftUI snapshots/anchors. Следующий архитектурный шаг:

1. Оставить SwiftUI вокруг Terminal: Voice tab, drawer, root header, settings/debug buttons.
2. Внутри Terminal сделать отдельный UIKit-owned container для уровней `projects`, `tabs`,
   `chat`.
3. Вертикальные списки `projects`/`tabs` должны принадлежать UIKit scroll/list view, чтобы
   offset жил в UIKit и не зависел от пересоздания SwiftUI `View`.
4. Горизонтальный interactive back/push тоже должен принадлежать этому container, чтобы палец
   двигал реальные постоянные pages, а не SwiftUI дерево, которое одновременно пересчитывает
   layout.
5. SwiftUI можно оставить внутри ячеек/строк через hosting только если это не ломает scroll
   ownership; иначе строки надо делать UIKit-native.

Практический критерий готовности следующей архитектуры:

- `projects -> tabs` и `tabs -> projects` оба могут быть animated/interactive;
- projects scroll не меняется в момент клика по project;
- после back projects scroll остаётся в том же месте;
- если пользователь начинает скроллить сразу после back, поздний refresh/settle не сбрасывает
  offset;
- в логах нет `back from=tabs` с `worst=70-90ms` на обычном быстром свайпе;
- при cached/fresh tabs открытие project не ждёт state refresh, а сразу интерактивно.
