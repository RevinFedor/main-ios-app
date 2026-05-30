# CoreDevice: "No provider was found" после обновления Xcode

## Симптом
В Xcode → Window → Devices and Simulators жёлтый баннер:
> The developer disk image could not be mounted on this device.

В терминале каждая команда `devicectl` начинается со строки:
```
Failed to load provisioning paramter list due to error:
Error Domain=com.apple.dt.CoreDeviceError Code=1002
"No provider was found."
```

iPhone в `xcrun devicectl list devices` со статусом `connected (no DDI)` или `unavailable`. Wireless деплой невозможен, через Xcode UI тоже — кнопка Run неактивна или вылетает с той же ошибкой.

## Что пробовали и почему не сработало

1. **Подозрение на VPN (AmneziaVPN/wireguard-go).** Убивали процесс — фоновый сервис `AmneziaVPN-service` сразу его перезапускал. Даже когда default route шёл через `en0`, ошибка оставалась. Локальный Bonjour работал нормально (`dns-sd -B _services._dns-sd._udp local.` находил AirPlay/RAOP), iPhone резолвился как `iPhone.local → 192.168.0.101`. VPN был ложным следом.
2. **Подозрение на stale pairing (83 дня без подключения).** `pairingState: paired`, но `tunnelState: unavailable`. Гипотеза: pairing протух. На самом деле devicectl восстанавливает pairing при USB-коннекте автоматически — это не было корнем проблемы.
3. **Подозрение на DDI/iOS mismatch.** Сначала Xcode 26.2 + iOS 26.3.1 (DDI старше iOS) — обновили Xcode до 26.4.1, DDI стал свежее (build 17E202), но ошибка `No provider was found` осталась. То есть mismatch версий был сопутствующим, не основным.

## Корень проблемы

После обновления Xcode (особенно с major-версии или из беты в RC) **First Launch Experience не переустанавливает `XcodeSystemResources.pkg`**, если detect что версии фреймворков совпадают. Этот пакет содержит провайдеры CoreDevice — без него весь стек выдаёт `No provider was found`, даже когда DDI совместим и iPhone доступен.

Apple подтвердили это на forums.developer.apple.com/forums/thread/764196 как известный баг.

## Решение

```bash
sudo installer -pkg /Applications/Xcode.app/Contents/Resources/Packages/XcodeSystemResources.pkg -target /
```

Установка ~30 секунд. После завершения статус iPhone в `xcrun devicectl list devices` меняется с `connected (no DDI)` на `available (paired)` без перезагрузки Mac. Применять каждый раз после обновления Xcode.

## Связанное

- `fact-wireless-deploy.md` — как устроен деплой целиком, какие компоненты Apple задействованы.
