# Xcode на маленьком диске: что жрёт, что переносится

Xcode съедает 30–250 ГБ, и это **не** `Xcode.app` (4-15 ГБ). Жирное лежит вне bundle и не видно через `du /Applications/Xcode.app`. На внутреннем 228 ГБ диске однажды осталось 294 МБ свободного — почти все съел кеш символов.

## Где лежит большое

| Путь | Что | Типичный размер |
|---|---|---|
| `~/Library/Developer/Xcode/iOS DeviceSupport/<iPhoneModel> <iOS-build>/` | Символы каждой iOS-сборки которую Xcode видел | ~5 ГБ × N версий |
| `/Library/Developer/CoreSimulator/Volumes/iOS_<build>/` | Симуляторные runtime'ы | 7-10 ГБ × N версий |
| `~/Library/Developer/Xcode/DerivedData/` | Кеш билдов | растёт, легко 20-50 ГБ |
| `/Applications/Xcode.app` | Сам Xcode | 4-15 ГБ |
| `~/Library/Developer/CoreSimulator/` | Данные текущих симуляторных сессий | 1-3 ГБ |

Размеры точно: `du -sh <path>`.

## Что МОЖНО перенести на внешний диск (symlink)

**`iOS DeviceSupport` — главный кандидат.** Это просто кеш символов; если symlink порвётся, Xcode перекачает за 5-15 мин. Безопасно:

```bash
mkdir -p /Volumes/ExtSSD/XcodeSupport
rsync -a ~/Library/Developer/Xcode/iOS\ DeviceSupport/ \
        /Volumes/ExtSSD/XcodeSupport/iOS\ DeviceSupport/
rm -rf ~/Library/Developer/Xcode/iOS\ DeviceSupport
ln -s "/Volumes/ExtSSD/XcodeSupport/iOS DeviceSupport" \
       ~/Library/Developer/Xcode/iOS\ DeviceSupport
```

Xcode не отличает symlink от папки — пишет «туда же где всегда».

**Старые версии DeviceSupport удалять можно безопасно.** Когда iPhone обновился с 26.3 на 26.5 — папки `iPhone16,1 26.3 (...)` больше не нужны, Xcode не вернётся к ним. Удаление — мгновенная экономия 5 ГБ × N.

## Что НЕЛЬЗЯ перенести symlink'ом

**Simulator runtimes (Xcode 16+).** Раньше лежали в `/Library/Developer/CoreSimulator/Profiles/Runtimes/*.simruntime` — пакеты-файлы, переносились symlink'ом. На Xcode 16+ это **отдельные APFS-тома**, смонтированные системой в `/Library/Developer/CoreSimulator/Volumes/iOS_<build>/`. Видно через `df -h | grep CoreSimulator`. Symlink не сработает — тома монтируются по фиксированному пути на старте.

Хочешь экономить — удаляй ненужные runtime'ы через Xcode → Settings → Platforms → swipe left. Не пытайся двигать вручную.

**`Xcode.app` технически можно** перенести на внешний (Apple это поддерживает), но почти бесполезно — 4-15 ГБ при типичных 50+ ГБ DeviceSupport+Runtimes. Плюс ловушки: при отключении внешнего диска `xcode-select` ломается; пробелы в имени тома (`Macintosh HD`) ломают build-скрипты.

## Copying shared cache symbols — что это и почему так долго

При первом подключении iPhone после обновления iOS Xcode пишет жёлтый баннер «Copying shared cache symbols from iPhone (N% completed)». Это не баг — Xcode копирует **dyld shared cache** с устройства (UIKit, Foundation, всё системное), извлекает имена функций и кладёт в `~/Library/Developer/Xcode/iOS DeviceSupport/<iPhoneModel> <iOS-build>/`. Без этого дебагер не покажет читаемый stack trace на крэше внутри UIKit.

**5–15 мин по USB, на WiFi обрывается и стартует процентовку с нуля.** Физически Xcode не теряет уже скаченное: внутри папки сборки лежат `.copying_lock` и `.processing_lock` — маркеры что копирование в процессе. На следующем подключении iPhone Xcode проверит лок-файлы, найдёт уже скачанные части и **продолжит с дельты**, хотя UI показывает «0%». То есть процентовка в баннере врёт: реальная работа резюмируется.

**Когда триггерится:**
- Первое подключение нового iPhone.
- iPhone обновился (новый shared cache → новые символы).
- Обновление Xcode (иногда).

**Когда **не** триггерится:**
- Каждый билд. После первого успешного копирования iPhone живёт без баннера.

## Минимальный recovery если что-то сломалось

Если symlink на внешний диск порвался / внешний диск умер:

```bash
rm ~/Library/Developer/Xcode/iOS\ DeviceSupport
mkdir ~/Library/Developer/Xcode/iOS\ DeviceSupport
```

Подключить iPhone к Xcode → Xcode сам перекачает символы (5-15 мин по USB). Никаких настроек менять не надо.

## Связанное

- `fact-wireless-deploy.md` — как устроен деплой целиком, USB vs WiFi для копирования.
