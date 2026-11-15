# Winoid

Android-приложения и игры в отдельных окнах Windows. Внутри — WSL2, Waydroid
(LineageOS) и менеджер на PowerShell 7 + WPF.

> **Переименование.** Проект назывался Winndroid. Настройки, platform-tools и
> ядро из `%LOCALAPPDATA%\Winndroid` переносятся в `%LOCALAPPDATA%\Winoid`
> автоматически при первом запуске.

**[Скачать установщик](https://github.com/Sergey35853/winoid/releases/latest)**
· [Исходники и portable-zip](https://github.com/Sergey35853/winoid/releases)

> **Статус: альфа.** Проект личный, публикуется для энтузиастов. Бэкенд
> (WSL-ядро с binder, Waydroid, GApps, libndk) ставится кнопкой
> **«Настроить Android»** в менеджере (экспериментально). Ядро, GApps и libndk
> скачиваются на машине пользователя и не входят в поставку.

![Менеджер Winoid](docs/screenshot-manager.png)

## Что умеет

- Показывает список запускаемых Android-приложений (через `PackageManager`
  самого Android, а не `waydroid app list`) и ищет по имени/пакету.
- Открывает каждое приложение в отдельном окне Windows.
- Живой кадр через `PrintWindow`, изменение размера, сворачивание и
  восстановление, равномерное масштабирование с чёрными полями.
- Мышь, перетаскивание, колесо и физическая клавиатура уходят в Android.
- Устанавливает APK кнопкой или перетаскиванием файла в окно менеджера.
- Создаёт ярлыки на рабочем столе: сразу с общим значком, затем подставляет
  родную иконку приложения.
- Кнопка «Настройки Android» открывает системные настройки в отдельном окне.
- Кнопка «Перезапустить Android» поднимает сессию Waydroid заново, если окна
  пропали после сна Windows или сбоя графики WSL.
- Показывает индикатор запуска, пока приложение не отрисует первый кадр.
  Если кадра нет 45 секунд, индикатор остаётся и объясняет причину.
- Проверяет бэкенд и запускает автоматическую настройку Android, если
  Waydroid ещё не установлен.
- Несколько окон одновременно; закрытие окна закрывает приложение, закрытие
  менеджера возвращает исходные окна на экран.

## Требования

- Windows 11 22H2 или новее (WSL2 + WSLg). На Windows 10 не проверялось.
- WSL2 с включённым systemd — скрипт настройки включает его сам.
- Ядро WSL с binder — скрипт ставит готовое из релиза
  `kernel-6.18.58.1`.
- Waydroid 1.6.x, инициализированный с GApps, если нужен Play Store.
- `persist.waydroid.multi_windows = true`.
- libndk, если нужны ARM-приложения и игры.
- PowerShell 7.
- Android platform-tools (`adb.exe`) — скрипт скачивает при необходимости.

GApps, Play Store и libndk **не входят** в поставку: скрипт скачивает и
устанавливает их на машине пользователя. Это осознанное ограничение по
лицензиям.

## Быстрый старт

Если бэкенд уже настроен (Waydroid стоит в WSL, сессия запускается):

1. Проверьте сессию:

   ```bash
   waydroid status
   # Session: RUNNING
   ```

   Если сессия не запущена:

   ```bash
   systemctl --user start waydroid-session.service
   ```

2. ADB для запуска не обязателен: Winoid сам использует `adb` внутри WSL,
   потому что Windows-VPN часто блокирует `192.168.240.0/24`. Windows-ADB
   нужен только как резерв и для установки APK:

   ```powershell
   adb connect 192.168.240.112:5555
   adb devices
   ```

3. Запустите `Winoid.cmd` (или `pwsh -File Winoid.ps1` из исходников).

4. Выберите приложение и нажмите «Запустить в отдельном окне». Двойной клик
   по строке делает то же самое.

## Как открыть Winoid и настройки Android

Окно менеджера открывается тремя способами:

- ярлык **Winoid** на рабочем столе (создаётся установщиком);
- **Пуск → Winoid**;
- файл `Winoid.cmd` в папке установки (или в папке исходников).

Если менеджер уже запущен, повторный запуск ярлыка не создаёт второе окно,
а поднимает существующее.

В главном окне:

- **Настройки Android** — системные настройки Android в отдельном окне;
- **Перезапустить Android** — перезапуск сессии Waydroid. Помогает, если окна
  Android исчезли после сна Windows или сбоя графики WSL;
- **Диск Android** — общая память Android в проводнике;
- **Ярлык на рабочем столе** — ярлык выбранного приложения с его родной иконкой.

## Настройка

Менеджер читает необязательный файл
`%LOCALAPPDATA%\Winoid\config.json`:

```json
{
  "wslDistro": "",
  "adbSerial": "192.168.240.112:5555"
}
```

- `wslDistro` — имя дистрибутива WSL (`wsl -l -q`). Пусто — дистрибутив по
  умолчанию.
- `adbSerial` — адрес Android для ADB. По умолчанию Waydroid использует
  `192.168.240.112:5555`.

Переменные окружения `WINOID_WSL_DISTRO` и `WINOID_ADB_SERIAL` имеют
приоритет над файлом.

ADB ищется по порядку:

1. `platform-tools\adb.exe` рядом с `Winoid.ps1`;
2. `%LOCALAPPDATA%\Winoid\platform-tools\adb.exe`;
3. `adb.exe` в `PATH`;
4. `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`;
5. `C:\platform-tools\adb.exe`.

## Автоматическая настройка бэкенда

Если менеджер пишет «Бэкенд не настроен», нажмите **«Настроить Android»**.
Откроется отдельное окно `Setup-Backend.ps1`. Скрипт:

1. Проверит WSL2 и Ubuntu 24.04; при отсутствии предложит установить
   дистрибутив.
2. Скачает ядро с binder и минимальные модули из релиза
   [`kernel-6.18.58.1`](https://github.com/Sergey35853/winoid/releases/tag/kernel-6.18.58.1),
   сохранит резервную копию `.wslconfig` и перезапустит WSL.
3. Установит Waydroid из `repo.waydro.id`.
4. Скачает образы Android с GAPPS (около 3 ГБ) с `ota.waydro.id`.
5. Установит libndk через
   [waydroid_script](https://github.com/casualsnek/waydroid_script).
6. Создаст сервис автозапуска сессии Waydroid и подключит ADB.

Нужны интернет, около 8–10 ГБ свободного места и подтверждение на каждом
опасном шаге. **Ядро и `.wslconfig` общие для всех дистрибутивов WSL**;
скрипт делает резервную копию и предупреждает перед `wsl --shutdown`.
Автоматическая настройка пока экспериментальная: если что-то пошло не так,
ниже есть ручная инструкция.

Проверить или запустить настройку отдельно:

```powershell
pwsh -File .\Setup-Backend.ps1 -Mode Check    # только диагностика
pwsh -File .\Setup-Backend.ps1 -Mode Install  # установка с подтверждениями
pwsh -File .\Setup-Backend.ps1 -Mode Install -DryRun  # показать план
```

## Как поднять бэкенд вручную

Команды выполняются в WSL. Этот путь — запасной, если автоматическая настройка
не подошла.

1. Установите WSL2 и Ubuntu 24.04, включите systemd в `/etc/wsl.conf`:

   ```ini
   [boot]
   systemd=true
   ```

2. Возьмите готовое ядро и модули из релиза
   [`kernel-6.18.58.1`](https://github.com/Sergey35853/winoid/releases/tag/kernel-6.18.58.1)
   (или соберите по [`kernel/README.md`](kernel/README.md)) и укажите ядро в
   `%UserProfile%\.wslconfig`:

   ```ini
   [wsl2]
   kernel=C:\\Users\\<user>\\AppData\\Local\\Winoid\\kernel\\bzImage
   ```

   Модули распакуйте в `/lib/modules/$(uname -r)/` и выполните
   `depmod -a "$(uname -r)"`. `wsl --shutdown` после изменения. Ядро общее
   для всех дистрибутивов WSL.

3. Установите Waydroid:

   ```bash
   sudo apt install -y curl ca-certificates
   curl -s https://repo.waydro.id | sudo bash
   sudo apt install -y waydroid
   sudo waydroid init -s GAPPS
   ```

4. Включите нужные свойства:

   ```bash
   sudo waydroid prop set persist.waydroid.multi_windows true
   sudo waydroid prop set persist.waydroid.no_background_subsurface true
   ```

5. Запустите контейнер и сессию от своего пользователя:

   ```bash
   sudo systemctl start waydroid-container
   waydroid session start
   ```

   Для автозапуска можно оформить пользовательский сервис
   `~/.config/systemd/user/waydroid-session.service` и включить linger:

   ```bash
   loginctl enable-linger "$USER"
   systemctl --user enable --now waydroid-session.service
   ```

6. Установите libndk, если нужны ARM-приложения. Удобный способ —
   [waydroid_script](https://github.com/casualsnek/waydroid_script):

   ```bash
   git clone https://github.com/casualsnek/waydroid_script
   cd waydroid_script
   sudo python3 -m venv venv
   sudo venv/bin/pip install -r requirements.txt
   sudo venv/bin/python3 main.py install libndk
   ```

7. Подключите ADB с Windows:

   ```powershell
   adb connect 192.168.240.112:5555
   ```

   Если адрес недоступен, посмотрите `IP address` в `waydroid status` и
   используйте его. Адрес по умолчанию — `192.168.240.112`.

## Ограничения

- **Play Integrity, банковские приложения, DRM/Widevine и античиты** не
  работают или работают частично. Это ограничение Waydroid, а не менеджера.
- **Play Store и графика WSL.** Запуск Play Store в WSL2 может уронить
  `weston`/`msrdc`: все окна Android пропадают. Winoid предупреждает перед
  запуском; после сбоя нажмите **Перезапустить Android**. Это ограничение
  WSLg/Waydroid, а не самого приложения.
- **Сон Windows и WSLg.** После сна или сбоя графики окна Android могут стать
  невидимыми. Кнопка **Перезапустить Android** возвращает их; если не помогло,
  выполните `wsl --shutdown` и запустите Winoid заново.
- **Тяжёлые Unity-игры** могут не отрисовать кадр. В частности, Infinite
  Magicraid даёт чёрный экран и внутри самого Android (`adb exec-out screencap`
  тоже чёрный): это не баг окна, а связка приложения с программным
  Vulkan/SwiftShader и сетью. Окно остаётся с индикатором и объяснением.
- **GApps и Google-аккаунт.** Использование GApps может нарушать условия
  Google; ответственность на пользователе. Play Store может считать устройство
  непроверенным — ID регистрируется на
  <https://www.google.com/android/uncertified/>.
- **Ядро WSL общее.** Автоматическая настройка меняет `.wslconfig` и ядро для
  всех дистрибутивов, делает резервную копию и предупреждает перед
  `wsl --shutdown` (он закрывает все дистрибутивы).
- **Windows 10** не проверялся; нужны WSL2 и WSLg из Windows 11.
- Установщик пока не подписан, SmartScreen может показать предупреждение.

## Планы

- Проверка обновлений менеджера.
- Значки приложений в списке.
- Мастер обновления ядра и восстановления бэкенда без полной переустановки.

## Разработка

```powershell
# запуск из исходников
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Winoid.ps1

# автозапуск приложения для проверки
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Winoid.ps1 -Launch org.telegram.messenger

# установка APK без диалога
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Winoid.ps1 -Install C:\path\app.apk
```

Основные части `Winoid.ps1`:

- `NativeWin` — Win32: поиск окон, `PrintWindow`, стили, фокус.
- `FrameGrabber` — DIB-секция и захват кадра без копирования 14 МБ на кадр.
- `AdbShell` — постоянная `adb shell`-сессия (через WSL-ADB), ввод с задержкой
  ~15 мс на команду.
- `New-AppWrapper` — окно приложения, масштабирование, ввод, индикатор.
- `assets\winoid-icon.dex` — помощник `WinoidIcon`: список приложений с
  подписями и извлечение родных иконок через `app_process`.
- `assets\iconjob.ps1` — отдельный процесс, который выгружает иконку, собирает
  `.ico` и обновляет ярлык, не блокируя окно менеджера.
- таймеры — кадры (40 мс), загрузка, установка, сессия, ADB health check.

## Сборка установщика

```powershell
winget install JRSoftware.InnoSetup
& "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" installer\Winoid.iss
```

Готовый файл появится в `dist\Winoid-Setup-<версия>.exe`. GitHub Actions
собирает установщик и portable-zip по тегу `v*` и прикрепляет их к релизу.

## Лицензии и благодарности

Код менеджера — MIT (см. `LICENSE`). Waydroid, LineageOS, Android и
GApps распространяются по своим лицензиям и не входят в этот репозиторий.
Проект не связан с Google, Microsoft или Waydroid.
