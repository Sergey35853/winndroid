# WSL-ядро с binder для Waydroid

Готовая сборка ядра WSL2, с которой работает бэкенд Winndroid.

## Файлы

| Файл | Размер | Назначение |
| --- | --- | --- |
| `bzImage-6.18.58.1` | 17,7 МБ | ядро WSL2 с binder/binderfs |
| `config-6.18.58.1` | 228 КБ | точный конфиг сборки |
| `modules-slim-6.18.58.1.tar.gz` | 2,4 МБ | минимальный набор модулей: netfilter, NAT и bridge для LXC/Waydroid |

Ключевые опции конфига:

```
CONFIG_ANDROID_BINDER_IPC=y
CONFIG_ANDROID_BINDERFS=y
CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"
CONFIG_VETH=y
CONFIG_BRIDGE=y
CONFIG_OVERLAY_FS=y
CONFIG_BINFMT_MISC=y
CONFIG_NF_NAT=y
CONFIG_IP_NF_TARGET_MASQUERADE=m
CONFIG_BRIDGE_NETFILTER=m
```

## Источник и лицензия

Ядро собрано из исходников
[microsoft/WSL2-Linux-Kernel](https://github.com/microsoft/WSL2-Linux-Kernel),
тег [`linux-msft-wsl-6.18.58.1`](https://github.com/microsoft/WSL2-Linux-Kernel/tree/linux-msft-wsl-6.18.58.1),
без изменения исходного кода. Отличается только конфигурация сборки.
Лицензия ядра — GPL-2.0; исходники доступны по ссылке выше.

## Сборка

```bash
git clone --depth 1 --branch linux-msft-wsl-6.18.58.1 \
  https://github.com/microsoft/WSL2-Linux-Kernel.git
cd WSL2-Linux-Kernel
cp /path/to/config-6.18.58.1 .config
make olddefconfig
make -j"$(nproc)"
# arch/x86/boot/bzImage — готовое ядро
```

На практике ядро сообщает версию `6.18.58.1-microsoft-standard-WSL2+`
(суффикс `+` появляется, когда сборочное дерево отличается от коммита).
Поэтому модули нужно ставить в каталог `/lib/modules/$(uname -r)/`, а не в
каталог с фиксированным именем. Готовые `bzImage` и `modules-slim` — это
согласованная пара; при пересборке ядра пересоберите и модули.

## Установка вручную

```bash
# внутри WSL, от root
tar -xzf modules-slim-6.18.58.1.tar.gz -C "/lib/modules/$(uname -r)/"
depmod -a "$(uname -r)"
```

Путь к `bzImage` прописывается в `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
kernel=C:\\Users\\<user>\\AppData\\Local\\Winndroid\\kernel\\bzImage
```

После изменения `.wslconfig` выполните `wsl --shutdown` и запустите WSL снова.

## Контрольные суммы SHA-256

```
B620BD76366DAEFCB0FC010918B46FA7CBB21B70BA989EB59341A7EC9349C34A  bzImage-6.18.58.1
374BE979B3260F14632C92730E49695F7D694F4E6C8098294F2E33F56A8D8AE3  config-6.18.58.1
0AD711FA66CCA33ED313E03534940FE281E6ACD81C553F5D75F69DF2C4F03ACE  modules-slim-6.18.58.1.tar.gz
```
