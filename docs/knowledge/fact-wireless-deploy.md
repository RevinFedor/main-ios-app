# Wireless deploy: `./deploy.sh`

Скрипт собирает Habit Tracker и устанавливает на физический iPhone по WiFi одной командой. Открывать Xcode не нужно.

```bash
./deploy.sh           # полный цикл: диагностика → сборка → установка
./deploy.sh --check   # только диагностика, без сборки
```

Логи каждого запуска: `deploy-logs/deploy-<timestamp>.log` (диагностика, ANSI стрипается) и `deploy-logs/build-<timestamp>.log` (xcodebuild). Папка в `.gitignore`.

## Free dev cycle: 7 дней

Provisioning profile у бесплатного Apple ID живёт ~7 дней. После — иконка приложения на iPhone становится с крестиком, запуск выдаёт "Untrusted Developer". Решение: запустить `./deploy.sh` снова — `xcodebuild -allowProvisioningUpdates` (в скрипте) выпускает свежий profile автоматически. USB-кабель не нужен.

При **первом** запуске нового сертификата iOS требует ручного Trust:
Настройки → Основные → пролистать вниз → VPN и управление устройством → ПО разработчика → выбрать Apple ID → Доверять.

## Сборка требует iOS Simulator

`xcodebuild` отказывается компилировать под `id=<iPhone UDID>` если **ни одного** iOS Simulator runtime не установлено — даже когда target физический iPhone. Сообщение: `iOS X.Y is not installed. Please download and install the platform from Xcode > Settings > Components`. Качается ~8 GB разово.

**Версия симулятора НЕ обязана совпадать с iOS на iPhone.** Достаточно любого runtime ≥ `IPHONEOS_DEPLOYMENT_TARGET` проекта (у нас 18.0 на widget-таргете). Установлен симулятор iOS 26.1 → можно билдить под iPhone с iOS 26.5. Это решает интуитивный вопрос *"мне надо обновлять симулятор при каждом апдейте iPhone?"* — нет, не надо.

Сама **установка** (`xcrun devicectl device install app`) симулятор не требует — собранный `.app` ставится без него.

→ Что ещё жрёт место в Xcode и что можно перенести на внешний диск: `fact-xcode-disk-usage.md`.

## Xcode 26 убрал "Connect via network"

В старых Xcode галочку ставили вручную в Window → Devices and Simulators. В Xcode 26 чекбокса больше нет — wireless коннект **автоматический** через CoreDevice, если iPhone в той же WiFi-сети что и Mac, и был хоть раз спарен через USB. Признак работающего wireless: `xcrun devicectl list devices` показывает `transportType: localNetwork`.

## Auto-wake CoreDevice tunnel (deploy.sh)

После Mac reboot, обновления iOS на iPhone, или долгого простоя — CoreDevice tunnel может стоять в `tunnelState: unavailable` даже когда iPhone в той же WiFi и резолвится через Bonjour. `xcodebuild` отказывается билдить под `id=<UDID>` в таком состоянии (`Unable to find a destination matching the provided destination specifier`).

**Симптом для юзера:** `./deploy.sh` фейлится на сборке со списком только simulator destinations, iPhone в списке нет.

**Корень:** CoreDevice services которые держат tunnel — это **background processes**, поднимаемые Xcode'ом при первом обращении к Devices. Если Xcode не открывался — services не подняты. Manual fix: открыть Xcode → Window → Devices and Simulators → подождать пока iPhone подсветится зелёным, потом можно закрыть UI (но **не Cmd+Q**, иначе services убьются).

**Автоматизация в deploy.sh:** pre-step проверяет `probe_tunnel()`. Wake триггерится **только** при `unavailable / unknown / ERROR / ""` — `disconnected` (sleeping iPhone) НЕ повод ждать, `devicectl device install app` сам поднимет туннель из этого состояния за пару секунд.

1. `open -gja Xcode` — поднимает Xcode в **background** (без UI, без foreground). Welcome-window всё равно нарисуется при cold launch (`-j` его не подавляет), но сервисы CoreDevice стартуют независимо — окно визуальный артефакт, не блокер.
2. Polls `probe_tunnel` каждые 3 сек до 90 сек, успех = `connected` ИЛИ `disconnected` (оба означают что services живы).
3. Если tunnel поднялся — продолжает.
4. Если 90с не хватило — warning'ит юзера про first-time "Preparing iPhone" (одноразово после iOS major-update, может занять 2 мин).

**Анти-баг:** в ранней версии условие было `!= connected && != NONE` — срабатывало на `disconnected` и зря жгло 90с на каждом запуске. Юзер заметил по логу *«я не понял, зачем он нуждал до этого 90 секунд, чтобы что? Я так понимаю, это ожидание копирования кэша, а он типа его проигнорировал»* — нет, кэш `Preparing iPhone` копируется только при iOS major upgrade или первом подключении после Xcode update, не при каждом `./deploy.sh`.

**Auto-close при выходе.** Если скрипт сам поднимал Xcode (был НЕ запущен до этого) — `trap cleanup_xcode EXIT INT TERM` закрывает его в конце. Если Xcode уже был открыт юзером — НЕ трогает. Принцип идемпотентности — см. `methodology/диагностика-apple.md::Идемпотентность tooling`.

```bash
XCODE_WAS_RUNNING=false
pgrep -xf "/Applications/Xcode.app/Contents/MacOS/Xcode" &>/dev/null && XCODE_WAS_RUNNING=true

cleanup_xcode() {
    if [ "$XCODE_WAS_RUNNING" = "false" ] && pgrep -xf "..." &>/dev/null; then
        osascript -e 'tell application "Xcode" to quit'
        # AppleScript quit асинхронный — wait до 8с пока процесс реально умрёт
        for _ in 1 2 3 4 5 6 7 8; do
            sleep 1
            pgrep -xf "..." &>/dev/null || return
        done
        pkill -x Xcode   # hard-kill fallback
    fi
}
trap cleanup_xcode EXIT INT TERM
```

## Install retry на installcoordination_proxy

**Симптом:** после auto-wake Xcode скрипт доходит до Install шага, и фейлится с:
```
ERROR: Failed to install the app on the device. (com.apple.dt.CoreDeviceError error 3002)
       Could not get service com.apple.remote.installcoordination_proxy
       (IXRemoteErrorDomain error 5)
```

**Корень:** CoreDevice tunnel поднимается за ~10-30с, но `installcoordination_proxy` (сервис для установки .app) запускается медленнее. На свежем wake-up tunnel ready, а сервис ещё нет.

**Решение:** detect строки `installcoordination_proxy` / `IXRemoteErrorDomain error 5` / `CoreDeviceError error 3002` в выводе `devicectl device install app` → `sleep 25` → retry один раз. Это эмулирует то что Xcode UI делает в "Preparing iPhone" — он ждёт пока сервис не зарегистрируется.

## USB vs WiFi: транспорт выбирает CoreDevice, не скрипт

`./deploy.sh` передаёт в `xcrun devicectl device install app -d <UDID>` только UDID — путь до устройства не указывается. CoreDevice смотрит в свой реестр спаренных устройств и выбирает транспорт сам: USB приоритетнее WiFi, если кабель воткнут. Поэтому добавлять флаги в скрипт не нужно — воткнул USB → автоматически быстрее в 5-10×, отключил → fallback на WiFi.

Для **первого подключения** после обновления iOS Xcode копирует символы (см. `fact-xcode-disk-usage.md` § Copying shared cache symbols). Это 5+ ГБ. По WiFi обрывается на пакетлоссе и стартует процентовку с нуля (хотя физически продолжает с дельты — лок-файлы атомарны). По USB проходит за 5-15 мин без обрывов. Один раз скопировал по USB — дальше можно жить на WiFi.

## `tunnelState: disconnected` ≠ ошибка

`xcrun devicectl list devices` может показывать iPhone как `connected` с `tunnelState: disconnected`. Это не блокер: `devicectl device install app` сам поднимает туннель, монтирует DDI, ставит приложение, и через несколько секунд `tunnelState` становится `connected`. Скрипт диагностики **не должен** требовать `tunnelState: available` до запуска установки — достаточно `pairingState: paired`. Это был основной false-positive в первых версиях `./deploy.sh`.

## Диагностика сети: не доверяй `scutil --dns`

Поле `reach: Not Reachable` у `domain: local` в `scutil --dns` — **ненадёжный** индикатор работы Bonjour. На активном Mac с открытой сетью может постоянно показывать "Not Reachable" хотя mDNS работает нормально.

Реальный тест Bonjour:
```bash
timeout 2 dns-sd -B _services._dns-sd._udp local.
```
Если за 2 секунды нашлись сервисы (`_airplay`, `_companion-link`, etc.) — Bonjour живой. Прямой резолв конкретного устройства:
```bash
dns-sd -G v4 iPhone.local.
```

## VPN (AmneziaVPN/WireGuard) НЕ блокирует CoreDevice

Долго подозревал что VPN-туннель (`utun4`) ломает обнаружение iPhone. Факты которые **опровергают** эту гипотезу:

- VPN маршрутизирует только internet-трафик (`0/7`, `2/11`, etc. через `utun`), локальный multicast `224.0.0.251` идёт через физический `en0`.
- `dns-sd -B _services._dns-sd._udp local.` при включённом VPN находит AirPlay/RAOP в WiFi-сети.
- `iPhone.local` резолвится в локальный IP `192.168.0.101` корректно.
- После фикса XcodeSystemResources (см. `fix-coredevice-no-provider.md`) wireless деплой работает с включённым VPN.

Однако `wireguard-go` процесс **держит** интерфейс `utun4` даже после нажатия "Disconnect" в UI приложения — это вводит в заблуждение при диагностике. Сервис `AmneziaVPN-service` перезапускает `wireguard-go` если убить только его, поэтому для полного отключения нужен Cmd+Q всего приложения. Но **для wireless деплоя этого не требуется** — VPN можно оставить включённым.

## Категория ошибки → специфический тест

Скрипт использует подход "детерминированный тест на каждую категорию" вместо "метод исключения". См. `methodology/диагностика-apple.md` для общего принципа.

| Категория | Тест | Если "да" — категория подтверждена |
|---|---|---|
| iPhone не paired никогда | `devicectl list devices --json-output` → нет устройств | NEVER_PAIRED |
| iPhone paired | `connectionProperties.pairingState == "paired"` | READY (даже если tunnel disconnected) |
| Bonjour работает | `dns-sd -B _services._dns-sd._udp local.` находит ≥1 сервис за 2 сек | BONJOUR_OK |
| iPhone в WiFi видим | `dns-sd -G v4 <DeviceName>.local.` резолвится | IN_WIFI |
| VPN-туннель активен | `ifconfig utunX` имеет `inet` адрес | VPN_TUNNEL (информационно) |
| CoreDevice провайдер сломан | Каждая команда `devicectl` начинается с `Error Code=1002 "No provider was found"` | NEEDS_XCODESYSTEMRESOURCES_FIX |

Категория `VPN_TUNNEL` информационная, не блокирует деплой.

## Связанное

- `fix-coredevice-no-provider.md` — фикс самой частой ошибки.
- `fix-ios-stability.md` — соседние шрамы (widget deployment target, App Groups).
- `methodology/диагностика-apple.md` — принцип детерминированной диагностики.
