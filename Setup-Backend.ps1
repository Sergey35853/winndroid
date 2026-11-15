#Requires -Version 7.0
param(
    [ValidateSet('Menu', 'Check', 'Install')]
    [string]$Mode = 'Menu',
    [string]$Distro = '',
    [switch]$Yes,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
    $Host.UI.RawUI.WindowTitle = 'Winoid — настройка Android'
} catch { }

function Initialize-WinoidRoot {
    $newRoot = Join-Path $env:LOCALAPPDATA 'Winoid'
    $oldRoot = Join-Path $env:LOCALAPPDATA 'Winndroid'
    $moved = $false
    if ((Test-Path -LiteralPath $oldRoot) -and -not (Test-Path -LiteralPath $newRoot)) {
        try {
            Move-Item -LiteralPath $oldRoot -Destination $newRoot -ErrorAction Stop
            $moved = $true
        } catch { }
    }
    if ($moved) {
        try {
            $wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
            if (Test-Path -LiteralPath $wslConfig) {
                $changed = $false
                $out = foreach ($line in @(Get-Content -LiteralPath $wslConfig)) {
                    if ($line -match '^\s*kernel=' -and $line -match '[\\/]Winndroid[\\/]') {
                        $changed = $true
                        $line.Replace('\\Winndroid\\', '\\Winoid\\').Replace('\Winndroid\', '\Winoid\')
                    } else { $line }
                }
                if ($changed) {
                    Copy-Item -LiteralPath $wslConfig -Destination ("$wslConfig.winoid-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak') -Force
                    Set-Content -LiteralPath $wslConfig -Value ($out -join "`r`n") -Encoding utf8NoBOM
                }
            }
        } catch {
            try {
                if (-not (Test-Path -LiteralPath $oldRoot) -and (Test-Path -LiteralPath $newRoot)) {
                    Move-Item -LiteralPath $newRoot -Destination $oldRoot -ErrorAction Stop
                }
            } catch { }
            return $oldRoot
        }
    }
    if (Test-Path -LiteralPath $newRoot) { return $newRoot }
    return $oldRoot
}

$script:Wsl          = Join-Path $env:SystemRoot 'System32\wsl.exe'
$script:Root         = Initialize-WinoidRoot
$script:ConfigPath   = Join-Path $script:Root 'config.json'
$script:LogPath      = Join-Path $script:Root 'setup-backend.log'
$script:KernelDir    = Join-Path $script:Root 'kernel'
$script:KernelTag    = 'kernel-6.18.58.1'
$script:KernelVer    = '6.18.58.1'
$script:KernelUrl    = "https://github.com/Sergey35853/winoid/releases/download/$($script:KernelTag)/bzImage-$($script:KernelVer)"
$script:ModulesUrl   = "https://github.com/Sergey35853/winoid/releases/download/$($script:KernelTag)/modules-slim-$($script:KernelVer).tar.gz"
$script:KernelSha    = 'B620BD76366DAEFCB0FC010918B46FA7CBB21B70BA989EB59341A7EC9349C34A'
$script:ModulesSha   = '0AD711FA66CCA33ED313E03534940FE281E6ACD81C553F5D75F69DF2C4F03ACE'
$script:AdbSerial    = '192.168.240.112:5555'
$script:ReadmeUrl    = 'https://github.com/Sergey35853/winoid/blob/main/README.md#как-поднять-бэкенд'

if (-not (Test-Path -LiteralPath $script:Root)) {
    New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
}

function Write-Log([string]$Text) {
    try {
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    } catch { }
}

function Write-Head([string]$Text) {
    Write-Host ''
    Write-Host "== $Text ==" -ForegroundColor Cyan
    Write-Log "SECTION $Text"
}

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "-> $Text" -ForegroundColor Cyan
    Write-Log "STEP $Text"
}

function Write-Ok([string]$Text)    { Write-Host "   [ok] $Text" -ForegroundColor Green;  Write-Log "OK $Text" }
function Write-Warn([string]$Text)  { Write-Host "   [!]  $Text" -ForegroundColor Yellow; Write-Log "WARN $Text" }
function Write-Fail([string]$Text)  { Write-Host "   [x]  $Text" -ForegroundColor Red;    Write-Log "FAIL $Text" }
function Write-Info([string]$Text)  { Write-Host "        $Text" -ForegroundColor Gray }

function Confirm-Action([string]$Text) {
    if ($Yes) { return $true }
    $answer = Read-Host "$Text [y/N]"
    return ($answer -match '^(y|yes|д|да)$')
}

function Invoke-WslCapture {
    param([string[]]$Arguments, [int]$TimeoutSeconds = 120)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:Wsl
    foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return [pscustomobject]@{ Out = ''; Err = $_.Exception.Message; Code = -1 }
    }
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill($true) } catch { }
        return [pscustomobject]@{ Out = ''; Err = 'timeout'; Code = -1 }
    }
    return [pscustomobject]@{ Out = $outTask.Result; Err = $errTask.Result; Code = $p.ExitCode }
}

function Invoke-WslStream {
    param([string[]]$Arguments)
    Write-Log ("RUN wsl " + ($Arguments -join ' '))
    & $script:Wsl @Arguments
    return $LASTEXITCODE
}

function ConvertTo-BashCommand([string]$ScriptText) {
    $normalized = $ScriptText -replace "`r`n", "`n"
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($normalized))
    return "echo $b64 | base64 -d | bash"
}

function Invoke-RootScript {
    param(
        [string]$DistroName,
        [string]$ScriptText,
        [switch]$Capture,
        [int]$TimeoutSeconds = 900
    )
    $command = ConvertTo-BashCommand $ScriptText
    $args = @('-d', $DistroName, '-u', 'root', '--', 'bash', '-c', $command)
    if ($Capture) { return Invoke-WslCapture $args $TimeoutSeconds }
    return Invoke-WslStream $args
}

function Get-WslDistros {
    $r = Invoke-WslCapture @('--list', '--quiet') 30
    if ($r.Code -ne 0) { return @() }
    return @($r.Out -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-DistroVersion([string]$DistroName) {
    $r = Invoke-WslCapture @('--list', '--verbose') 30
    if ($r.Code -ne 0) { return 0 }
    foreach ($line in ($r.Out -split "`r?`n")) {
        if ($line -match ("^\s*\*?\s*" + [regex]::Escape($DistroName) + "\s+\S+\s+(\d+)\s*$")) {
            return [int]$matches[1]
        }
    }
    return 0
}

function Resolve-Distro {
    $list = Get-WslDistros
    if ($Distro) {
        if ($list -contains $Distro) { return $Distro }
        throw "Дистрибутив '$Distro' не найден. Доступны: $($list -join ', ')"
    }
    if (Test-Path -LiteralPath $script:ConfigPath) {
        try {
            $cfg = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
            if ($cfg.wslDistro -and ($list -contains [string]$cfg.wslDistro)) { return [string]$cfg.wslDistro }
        } catch { }
    }
    if ($list -contains 'Ubuntu-24.04') { return 'Ubuntu-24.04' }
    $ubuntu = @($list | Where-Object { $_ -like 'Ubuntu*' } | Select-Object -First 1)
    if ($ubuntu.Count -gt 0) { return $ubuntu[0] }
    if ($list.Count -eq 1) { return $list[0] }
    return $null
}

function Get-KernelState([string]$DistroName) {
    $r = Invoke-WslCapture @('-d', $DistroName, '--', 'sh', '-c',
        'uname -r; if grep -qw binder /proc/filesystems; then echo BINDER_OK; else echo BINDER_MISSING; fi') 60
    $lines = @($r.Out -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $release = if ($lines.Count -gt 0) { $lines[0] } else { '' }
    $binder = ($lines -contains 'BINDER_OK')
    $mods = Invoke-WslCapture @('-d', $DistroName, '--', 'sh', '-c',
        'test -f "/lib/modules/$(uname -r)/modules.dep" && echo MODS_OK || echo MODS_MISSING') 60
    return [pscustomobject]@{
        Release = $release
        Binder  = $binder
        Modules = ($mods.Out -match 'MODS_OK')
    }
}

function Get-WaydroidState([string]$DistroName) {
    $scriptText = @'
if command -v waydroid >/dev/null 2>&1; then
  echo WAYDROID_OK
  waydroid --version 2>/dev/null | head -1
else
  echo WAYDROID_MISSING
fi
if [ -f /var/lib/waydroid/images/system.img ] && [ -f /var/lib/waydroid/images/vendor.img ]; then echo IMAGES_OK; else echo IMAGES_MISSING; fi
if grep -q '^ro.dalvik.vm.native.bridge = libndk_translation.so' /var/lib/waydroid/waydroid.cfg 2>/dev/null; then echo NDK_OK; else echo NDK_MISSING; fi
if grep -q '^persist.waydroid.multi_windows = true' /var/lib/waydroid/waydroid.cfg 2>/dev/null; then echo MULTI_OK; else echo MULTI_MISSING; fi
if systemctl is-active --quiet waydroid-container 2>/dev/null; then echo CONTAINER_OK; else echo CONTAINER_STOPPED; fi
'@
    $r = Invoke-RootScript -DistroName $DistroName -ScriptText $scriptText -Capture -TimeoutSeconds 60
    $text = $r.Out
    $version = ''
    $lines = @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $idx = [Array]::IndexOf($lines, 'WAYDROID_OK')
    if ($idx -ge 0 -and $idx + 1 -lt $lines.Count -and $lines[$idx + 1] -notmatch '^[A-Z_]+$') {
        $version = $lines[$idx + 1]
    }
    return [pscustomobject]@{
        Installed  = ($text -match 'WAYDROID_OK')
        Version    = $version
        Images     = ($text -match 'IMAGES_OK')
        Libndk     = ($text -match 'NDK_OK')
        MultiWin   = ($text -match 'MULTI_OK')
        Container  = ($text -match 'CONTAINER_OK')
    }
}

function Get-SessionState([string]$DistroName) {
    $scriptText = @'
user=$(id -un)
uid=$(id -u)
echo "USER=$user"
echo "UID=$uid"
if id "$user" >/dev/null 2>&1; then
  if [ -f "/home/$user/.config/systemd/user/waydroid-session.service" ]; then echo SERVICE_FILE_OK; else echo SERVICE_FILE_MISSING; fi
  if grep -q '^Restart=always' "/home/$user/.config/systemd/user/waydroid-session.service" 2>/dev/null; then echo SERVICE_CURRENT; else echo SERVICE_OLD; fi
fi
linger=$(loginctl show-user "$user" -p Linger 2>/dev/null | cut -d= -f2)
[ "$linger" = "yes" ] && echo LINGER_OK || echo LINGER_OFF
export XDG_RUNTIME_DIR=/run/user/$uid
export WAYLAND_DISPLAY=wayland-0
export DISPLAY=:0
session=$(waydroid status 2>/dev/null | sed -n 's/^Session:[[:space:]]*//p')
echo "SESSION=$session"
'@
    $r = Invoke-WslCapture @('-d', $DistroName, '--', 'bash', '-c', (ConvertTo-BashCommand $scriptText)) 60
    $user = ''; $uid = ''; $session = ''
    foreach ($line in ($r.Out -split "`r?`n")) {
        if ($line -match '^USER=(.+)$') { $user = $matches[1].Trim() }
        elseif ($line -match '^UID=(\d+)$') { $uid = $matches[1] }
        elseif ($line -match '^SESSION=(.*)$') { $session = $matches[1].Trim() }
    }
    return [pscustomobject]@{
        User        = $user
        Uid         = $uid
        ServiceFile = ($r.Out -match 'SERVICE_FILE_OK')
        ServiceCurrent = ($r.Out -match 'SERVICE_CURRENT')
        Linger      = ($r.Out -match 'LINGER_OK')
        Session     = $session
    }
}

function Find-Adb {
    $local = Join-Path $script:Root 'platform-tools\adb.exe'
    if (Test-Path -LiteralPath $local) { return $local }
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Install-Adb {
    $dest = Join-Path $script:Root 'platform-tools'
    $zip = Join-Path $env:TEMP 'winoid-platform-tools.zip'
    $tmp = Join-Path $env:TEMP ('winoid-pt-' + [Guid]::NewGuid().ToString('N'))
    Write-Step 'Скачиваю Android platform-tools'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $src = Join-Path $tmp 'platform-tools'
    if (-not (Test-Path -LiteralPath (Join-Path $src 'adb.exe'))) { throw 'adb.exe не найден в архиве platform-tools' }
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Move-Item -LiteralPath $src -Destination $dest
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Write-Ok "ADB установлен: $dest"
    return (Join-Path $dest 'adb.exe')
}

function Save-RemoteFile([string]$Url, [string]$Destination, [string]$Sha256) {
    $attempts = 0
    while ($attempts -lt 2) {
        $attempts++
        $part = "$Destination.part"
        try {
            Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing
            $hash = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash
            if ($hash -ne $Sha256) { throw "контрольная сумма не совпала: $hash" }
            Move-Item -LiteralPath $part -Destination $Destination -Force
            return
        } catch {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            if ($attempts -ge 2) { throw "Не удалось скачать $Url : $($_.Exception.Message)" }
            Write-Warn 'Повторяю загрузку…'
            Start-Sleep -Seconds 2
        }
    }
}

function Get-ConfigSerial {
    if (Test-Path -LiteralPath $script:ConfigPath) {
        try {
            $cfg = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
            if ($cfg.adbSerial) { return [string]$cfg.adbSerial }
        } catch { }
    }
    return $script:AdbSerial
}

function Save-ManagerConfig([string]$DistroName, [string]$Serial) {
    $cfg = @{}
    if (Test-Path -LiteralPath $script:ConfigPath) {
        try {
            $old = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json -AsHashtable
            if ($old) { $cfg = $old }
        } catch { }
    }
    $cfg['wslDistro'] = $DistroName
    $cfg['adbSerial'] = $Serial
    $json = $cfg | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $script:ConfigPath -Value $json -Encoding utf8NoBOM
    Write-Ok "Настройки менеджера: $script:ConfigPath"
}

function Get-AdbState([string]$Serial) {
    $adb = Find-Adb
    if (-not $adb) { return [pscustomobject]@{ Path = ''; Online = $false; Serial = $Serial } }
    $null = & $adb connect $Serial 2>&1
    Start-Sleep -Seconds 2
    $devices = (& $adb devices 2>&1) -join "`n"
    return [pscustomobject]@{
        Path   = $adb
        Online = ($devices -match ([regex]::Escape($Serial) + '\s+device'))
        Serial = $Serial
    }
}

function Enable-WindowsAdbKey([string]$DistroName) {
    $adb = Find-Adb
    if (-not $adb) { return }
    $keyDir = Join-Path $env:USERPROFILE '.android'
    $keyPath = Join-Path $keyDir 'adbkey'
    $pubPath = "$keyPath.pub"
    if (-not (Test-Path -LiteralPath $pubPath)) {
        if (-not (Test-Path -LiteralPath $keyDir)) { New-Item -ItemType Directory -Path $keyDir -Force | Out-Null }
        $null = & $adb keygen $keyPath 2>&1
    }
    if (-not (Test-Path -LiteralPath $pubPath)) { throw 'Не удалось создать ключ ADB для Windows.' }
    $key = (Get-Content -LiteralPath $pubPath -Raw).Trim()
    if (-not $key) { throw 'Ключ ADB для Windows пуст.' }
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($key))
    $scriptText = @"
set -e
printf '%s' '$b64' | base64 -d > /tmp/winoid-adbkey.pub
lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- sh -c '
k=`$(cat)
grep -qF "`$k" /data/misc/adb/adb_keys 2>/dev/null || echo "`$k" >> /data/misc/adb/adb_keys
chown system:shell /data/misc/adb/adb_keys
chmod 640 /data/misc/adb/adb_keys
' < /tmp/winoid-adbkey.pub
rm -f /tmp/winoid-adbkey.pub
"@
    $r = Invoke-RootScript -DistroName $DistroName -ScriptText $scriptText -Capture -TimeoutSeconds 60
    if ($r.Code -ne 0) { throw "Не удалось авторизовать ключ ADB: $($r.Err.Trim())" }
}

function Show-Status([string]$DistroName) {
    Write-Head 'Проверка бэкенда'
    if (-not $DistroName) {
        Write-Fail 'Дистрибутив WSL не найден.'
        Write-Info 'Установите Ubuntu 24.04: wsl --install -d Ubuntu-24.04'
        return $false
    }
    $version = Get-DistroVersion $DistroName
    if ($version -eq 2) { Write-Ok "WSL2: $DistroName" } else { Write-Warn "WSL: $DistroName (версия $version, нужна 2)" }

    $kernel = Get-KernelState $DistroName
    if ($kernel.Binder) { Write-Ok "Ядро: $($kernel.Release) (binder)" }
    else { Write-Fail "Ядро: $($kernel.Release) — binder не найден" }
    if ($kernel.Modules) { Write-Ok 'Модули ядра на месте' } else { Write-Warn 'Модули ядра не установлены' }

    $wd = Get-WaydroidState $DistroName
    if ($wd.Installed) { Write-Ok "Waydroid: $($wd.Version)" } else { Write-Fail 'Waydroid не установлен' }
    if ($wd.Images) { Write-Ok 'Образы Android (GAPPS) на месте' } else { Write-Fail 'Образы Android не скачаны' }
    if ($wd.Libndk) { Write-Ok 'libndk (ARM-трансляция) включён' } else { Write-Warn 'libndk не установлен' }
    if ($wd.MultiWin) { Write-Ok 'multi_windows включён' } else { Write-Warn 'multi_windows выключен' }

    $session = Get-SessionState $DistroName
    if ($session.Session -eq 'RUNNING') { Write-Ok "Сессия Waydroid: RUNNING ($($session.User))" }
    else { Write-Warn "Сессия Waydroid: $($session.Session)" }
    if ($session.ServiceFile) { Write-Ok 'Сервис автозапуска сессии установлен' } else { Write-Warn 'Сервис автозапуска сессии не установлен' }
    if ($session.Linger) { Write-Ok 'Автозапуск пользовательских сервисов включён' } else { Write-Warn 'Linger выключен' }

    $serial = Get-ConfigSerial
    $adb = Get-AdbState $serial
    if (-not $adb.Path) { Write-Fail 'ADB не найден' }
    elseif ($adb.Online) { Write-Ok "ADB: $serial подключён" }
    else { Write-Warn "ADB: $serial не отвечает" }

    $ready = $kernel.Binder -and $wd.Installed -and $wd.Images -and $wd.Libndk -and ($session.Session -eq 'RUNNING')
    Write-Host ''
    if ($ready) { Write-Host 'Итог: бэкенд готов.' -ForegroundColor Green }
    else { Write-Host 'Итог: бэкенд не готов. Запустите «Настроить / восстановить».' -ForegroundColor Yellow }
    return $ready
}

function Install-Backend([string]$DistroName) {
    if (-not $DistroName) {
        Write-Step 'Установка Ubuntu 24.04'
        if ($DryRun) { Write-Info 'Будет выполнено: wsl --install -d Ubuntu-24.04 --no-launch'; return }
        if (-not (Confirm-Action 'Дистрибутив WSL не найден. Установить Ubuntu 24.04?')) { throw 'Нужен дистрибутив WSL2 с Ubuntu.' }
        $p = Start-Process -FilePath $script:Wsl -ArgumentList @('--install', '-d', 'Ubuntu-24.04', '--no-launch') -Verb RunAs -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "wsl --install завершился с кодом $($p.ExitCode). Возможно, нужна перезагрузка." }
        Start-Sleep -Seconds 5
        $DistroName = Resolve-Distro
        if (-not $DistroName) { throw 'Ubuntu 24.04 не появился в списке WSL. Перезагрузите Windows и запустите настройку снова.' }
        Write-Ok "Дистрибутив: $DistroName"
    }

    $version = Get-DistroVersion $DistroName
    if ($version -eq 1) {
        Write-Step "Перевод $DistroName на WSL2"
        if ($DryRun) { Write-Info 'Будет выполнено: wsl --set-version'; }
        else {
            if (-not (Confirm-Action "Дистрибутив $DistroName работает на WSL1. Перевести на WSL2? Это может занять несколько минут.")) { throw 'Нужен WSL2.' }
            $code = Invoke-WslStream @('--set-version', $DistroName, '2')
            if ($code -ne 0) { throw 'Не удалось перевести дистрибутив на WSL2.' }
        }
    }

    # systemd
    $pid1 = Invoke-WslCapture @('-d', $DistroName, '--', 'sh', '-c', 'ps -p 1 -o comm=') 30
    if ($pid1.Out.Trim() -ne 'systemd') {
        Write-Step 'Включение systemd в WSL'
        if ($DryRun) { Write-Info 'Будет добавлен [boot] systemd=true в /etc/wsl.conf и выполнен wsl --terminate'; }
        else {
            $scriptText = @'
set -e
if ! grep -q '^systemd=true' /etc/wsl.conf 2>/dev/null; then
  if grep -q '^\[boot\]' /etc/wsl.conf 2>/dev/null; then
    sed -i '/^\[boot\]/a systemd=true' /etc/wsl.conf
  else
    printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf
  fi
fi
'@
            $r = Invoke-RootScript -DistroName $DistroName -ScriptText $scriptText -Capture
            if ($r.Code -ne 0) { throw "Не удалось изменить /etc/wsl.conf: $($r.Err)" }
            Write-Info 'Перезапускаю WSL, чтобы включить systemd…'
            [void](Invoke-WslCapture @('--terminate', $DistroName) 30)
            $pid1 = Invoke-WslCapture @('-d', $DistroName, '--', 'sh', '-c', 'ps -p 1 -o comm=') 60
            if ($pid1.Out.Trim() -ne 'systemd') { throw 'systemd не запустился. Проверьте /etc/wsl.conf.' }
            Write-Ok 'systemd включён'
        }
    }

    # kernel
    $kernel = Get-KernelState $DistroName
    if (-not $kernel.Binder) {
        Write-Step "Установка ядра WSL $($script:KernelVer) с binder"
        if ($DryRun) {
            Write-Info "Будет скачано: $script:KernelUrl"
            Write-Info 'Будет обновлён %USERPROFILE%\.wslconfig (с резервной копией)'
            Write-Info 'Будет выполнен wsl --shutdown, затем установлены модули'
        } else {
            if (-not (Confirm-Action 'Ядро будет заменено для всех дистрибутивов WSL, затем WSL перезапустится. Продолжить?')) { throw 'Установка ядра отменена.' }
            if (-not (Test-Path -LiteralPath $script:KernelDir)) { New-Item -ItemType Directory -Path $script:KernelDir -Force | Out-Null }
            $bz = Join-Path $script:KernelDir 'bzImage'
            if (Test-Path -LiteralPath $bz) {
                $hash = (Get-FileHash -LiteralPath $bz -Algorithm SHA256).Hash
                if ($hash -eq $script:KernelSha) { Write-Ok 'Ядро уже скачано' }
                else { Save-RemoteFile $script:KernelUrl $bz $script:KernelSha; Write-Ok 'Ядро скачано' }
            } else {
                Save-RemoteFile $script:KernelUrl $bz $script:KernelSha
                Write-Ok 'Ядро скачано'
            }

            $wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
            $backup = "$wslConfig.winoid-$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
            if (Test-Path -LiteralPath $wslConfig) {
                Copy-Item -LiteralPath $wslConfig -Destination $backup
                $lines = @(Get-Content -LiteralPath $wslConfig)
            } else { $lines = @() }
            $kernelValue = 'kernel=' + ($bz -replace '\\', '\\')
            $out = New-Object System.Collections.Generic.List[string]
            $inWsl2 = $false
            $sectionSeen = $false
            $kernelSet = $false
            foreach ($line in $lines) {
                if ($line -match '^\s*\[(.+)\]\s*$') {
                    $inWsl2 = ($matches[1].Trim() -ieq 'wsl2')
                    if ($inWsl2) { $sectionSeen = $true }
                    $out.Add($line)
                    continue
                }
                if ($inWsl2 -and $line -match '^\s*kernel\s*=') {
                    if (-not $kernelSet) { $out.Add($kernelValue); $kernelSet = $true }
                    continue
                }
                $out.Add($line)
            }
            if (-not $sectionSeen) { $out.Add('[wsl2]'); $out.Add($kernelValue) }
            elseif (-not $kernelSet) {
                $idx = -1
                for ($i = 0; $i -lt $out.Count; $i++) { if ($out[$i] -match '^\s*\[wsl2\]\s*$') { $idx = $i; break } }
                $out.Insert($idx + 1, $kernelValue)
            }
            Set-Content -LiteralPath $wslConfig -Value ($out -join "`r`n") -Encoding utf8NoBOM
            Write-Ok "Конфигурация WSL обновлена (резервная копия: $backup)"

            Write-Info 'Перезапускаю WSL…'
            [void](Invoke-WslCapture @('--shutdown') 30)
            Start-Sleep -Seconds 5
            $kernel = Get-KernelState $DistroName
            if (-not $kernel.Binder) {
                if (Test-Path -LiteralPath $backup) { Copy-Item -LiteralPath $backup -Destination $wslConfig -Force }
                [void](Invoke-WslCapture @('--shutdown') 30)
                throw "Ядро не загрузилось с binder: $($kernel.Release). Вернул прежний .wslconfig."
            }
            Write-Ok "Ядро загружено: $($kernel.Release)"
        }
    } else {
        Write-Ok "Ядро с binder уже установлено: $($kernel.Release)"
    }

    # kernel modules (only for our kernel / when missing)
    $kernel = Get-KernelState $DistroName
    if (-not $kernel.Modules) {
        Write-Step 'Установка модулей ядра'
        if ($DryRun) { Write-Info "Будет скачано: $script:ModulesUrl"; }
        else {
            $tarWindows = Join-Path $env:TEMP 'winoid-modules-slim.tar.gz'
            if (-not (Test-Path -LiteralPath $tarWindows) -or (Get-FileHash -LiteralPath $tarWindows -Algorithm SHA256).Hash -ne $script:ModulesSha) {
                Save-RemoteFile $script:ModulesUrl $tarWindows $script:ModulesSha
            }
            $tarLinux = (Invoke-WslCapture @('-d', $DistroName, '--', 'wslpath', '-a', ($tarWindows -replace '\\', '/')) 120).Out.Trim()
            if (-not $tarLinux) { throw 'Не удалось получить путь к архиву модулей внутри WSL.' }
            $scriptText = @'
set -e
ver=$(uname -r)
mkdir -p "/lib/modules/$ver"
tar -xzf '__TAR__' -C "/lib/modules/$ver"
depmod -a "$ver"
cat >/etc/modules-load.d/winoid.conf <<'EOF'
xt_conntrack
xt_CHECKSUM
xt_MASQUERADE
iptable_mangle
iptable_nat
iptable_filter
ip_tables
br_netfilter
EOF
modprobe -a xt_conntrack xt_CHECKSUM xt_MASQUERADE iptable_mangle iptable_nat iptable_filter ip_tables br_netfilter 2>/dev/null || true
'@
            $scriptText = $scriptText -replace '__TAR__', ($tarLinux -replace "'", "'\''")
            $r = Invoke-RootScript -DistroName $DistroName -ScriptText $scriptText -Capture
            if ($r.Code -ne 0) { throw "Не удалось установить модули: $($r.Err)" }
            Write-Ok 'Модули ядра установлены'
        }
    } else {
        Write-Ok 'Модули ядра уже установлены'
    }

    # session user
    $session = Get-SessionState $DistroName
    if ($session.User -eq 'root') {
        Write-Step 'Создание пользователя для сессии Waydroid'
        if ($DryRun) { Write-Info 'Будет создан пользователь winoid и назначен пользователем по умолчанию.'; }
        else {
            if (-not (Confirm-Action 'WSL работает от root. Создать пользователя winoid для WSLg и сессии Waydroid?')) { throw 'Нужен обычный пользователь в WSL.' }
            $scriptText = @'
set -e
if ! id winoid >/dev/null 2>&1; then
  useradd -m -s /bin/bash winoid
fi
usermod -aG sudo winoid 2>/dev/null || true
echo 'winoid ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/winoid
chmod 440 /etc/sudoers.d/winoid
if grep -q '^\[user\]' /etc/wsl.conf 2>/dev/null; then
  sed -i '/^\[user\]/a default=winoid' /etc/wsl.conf
else
  printf '\n[user]\ndefault=winoid\n' >> /etc/wsl.conf
fi
'@
            $r = Invoke-RootScript -DistroName $DistroName -ScriptText $scriptText -Capture
            if ($r.Code -ne 0) { throw "Не удалось создать пользователя: $($r.Err)" }
            [void](Invoke-WslCapture @('--terminate', $DistroName) 30)
            Start-Sleep -Seconds 2
            $session = Get-SessionState $DistroName
            if ($session.User -ne 'winoid') { throw 'Не удалось переключить WSL на пользователя winoid.' }
            Write-Ok 'Пользователь winoid создан'
        }
    }

    # waydroid packages
    $wd = Get-WaydroidState $DistroName
    if (-not $wd.Installed) {
        Write-Step 'Установка Waydroid'
        if ($DryRun) {
            Write-Info 'Будет выполнено: apt-get update; apt-get install curl ca-certificates gnupg lzip git python3-venv'
            Write-Info 'Будет добавлен репозиторий repo.waydro.id и установлен пакет waydroid'
        } else {
            $scriptText = @'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates gnupg lzip git python3-venv acl
curl -s https://repo.waydro.id | bash
apt-get install -y waydroid
systemctl enable --now waydroid-container.service
'@
            $code = Invoke-RootScript -DistroName $DistroName -ScriptText $scriptText
            if ($code -ne 0) { throw 'Установка Waydroid не удалась. Смотрите вывод выше.' }
            Write-Ok 'Waydroid установлен'
        }
    } else {
        Write-Ok "Waydroid уже установлен: $($wd.Version)"
    }

    # android images (GAPPS)
    $wd = Get-WaydroidState $DistroName
    if (-not $wd.Images) {
        Write-Step 'Загрузка образов Android с GAPPS'
        Write-Info 'Это около 3 ГБ: system.img и vendor.img скачиваются с ota.waydro.id.'
        if ($DryRun) { Write-Info 'Будет выполнено: waydroid init -s GAPPS'; }
        else {
            if (-not (Confirm-Action 'Скачать образы Android с GAPPS (около 3 ГБ)?')) { throw 'Загрузка образов отменена.' }
            $scriptText = @'
set -e
mkdir -p /dev/binderfs
mountpoint -q /dev/binderfs || mount -t binder binder /dev/binderfs
systemctl enable --now waydroid-container.service
waydroid init -s GAPPS
'@
            $code = Invoke-RootScript -DistroName $DistroName -ScriptText $scriptText
            if ($code -ne 0) { throw 'waydroid init завершился с ошибкой. Смотрите вывод выше.' }
            Write-Ok 'Образы Android установлены'
        }
    } else {
        Write-Ok 'Образы Android уже скачаны'
    }

    # multi-windows
    $wd = Get-WaydroidState $DistroName
    if (-not $wd.MultiWin) {
        Write-Step 'Включение multi_windows'
        if ($DryRun) { Write-Info 'Будет добавлено persist.waydroid.multi_windows = true в waydroid.cfg'; }
        else {
            $scriptText = @'
set -e
cfg=/var/lib/waydroid/waydroid.cfg
sed -i '/^persist\.waydroid\.multi_windows[[:space:]]*=/d' "$cfg"
sed -i '/^\[properties\]/a persist.waydroid.multi_windows = true' "$cfg"
'@
            $r = Invoke-RootScript -DistroName $DistroName -ScriptText $scriptText -Capture
            if ($r.Code -ne 0) { throw "Не удалось включить multi_windows: $($r.Err)" }
            Write-Ok 'multi_windows включён'
        }
    } else {
        Write-Ok 'multi_windows уже включён'
    }

    # libndk
    $wd = Get-WaydroidState $DistroName
    if (-not $wd.Libndk) {
        Write-Step 'Установка libndk (ARM-трансляция)'
        Write-Info 'Используется waydroid_script: https://github.com/casualsnek/waydroid_script'
        if ($DryRun) { Write-Info 'Будет выполнено: waydroid_script install libndk'; }
        else {
            if (-not (Confirm-Action 'Скачать и установить libndk с waydroid_script?')) { throw 'Установка libndk отменена.' }
            $sessionNow = Get-SessionState $DistroName
            $uid = $sessionNow.Uid
            $user = $sessionNow.User
            $scriptText = @'
set -e
export DEBIAN_FRONTEND=noninteractive
systemctl stop waydroid-container.service 2>/dev/null || true
__STOP_SESSION__
if [ ! -d /opt/waydroid_script/.git ]; then
  rm -rf /opt/waydroid_script
  git clone --depth 1 https://github.com/casualsnek/waydroid_script /opt/waydroid_script
fi
cd /opt/waydroid_script
if [ ! -x venv/bin/python3 ]; then
  python3 -m venv venv
fi
venv/bin/pip install --quiet -r requirements.txt
venv/bin/python3 main.py install libndk
systemctl start waydroid-container.service 2>/dev/null || true
'@
            if ($uid) {
                $stop = "runuser -u $user -- env XDG_RUNTIME_DIR=/run/user/$uid systemctl --user stop waydroid-session.service 2>/dev/null || true"
            } else { $stop = 'true' }
            $scriptText = $scriptText -replace '__STOP_SESSION__', $stop
            $code = Invoke-RootScript -DistroName $DistroName -ScriptText $scriptText
            if ($code -ne 0) { throw 'Установка libndk не удалась. Смотрите вывод выше.' }
            $wd = Get-WaydroidState $DistroName
            if (-not $wd.Libndk) { throw 'libndk установлен, но свойство native.bridge не появилось в waydroid.cfg.' }
            Write-Ok 'libndk установлен'
        }
    } else {
        Write-Ok 'libndk уже установлен'
    }

    # session service
    $session = Get-SessionState $DistroName
    if (-not $session.ServiceFile -or -not $session.ServiceCurrent -or -not $session.Linger) {
        Write-Step 'Сервис автозапуска сессии Waydroid'
        if ($DryRun) { Write-Info 'Будет создан waydroid-session.service и включён linger'; }
        else {
            $user = $session.User
            $uid = $session.Uid
            if (-not $uid) { throw 'Не удалось определить пользователя WSL.' }
            $unit = @'
[Unit]
Description=Waydroid session (Android apps in separate windows)
After=dbus.service
Wants=dbus.service

[Service]
Type=simple
Environment=XDG_RUNTIME_DIR=/run/user/__UID__
Environment=WAYLAND_DISPLAY=wayland-0
Environment=DISPLAY=:0
Environment=PULSE_SERVER=unix:/mnt/wslg/PulseServer
ExecStartPre=/bin/sh -c 'i=0; while [ $i -lt 60 ]; do if [ -e "$XDG_RUNTIME_DIR/wayland-0" ] && [ -e "$XDG_RUNTIME_DIR/pulse/native" ]; then exit 0; fi; sleep 1; i=$((i+1)); done; exit 1'
ExecStart=/usr/bin/waydroid session start
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
'@
            $unit = $unit.TrimEnd() -replace '__UID__', $uid
            $unitB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($unit))
            $scriptText = @"
set -e
install -d -m 755 -o '$user' -g '$user' '/home/$user/.config/systemd/user'
echo '$unitB64' | base64 -d > '/home/$user/.config/systemd/user/waydroid-session.service'
chown '$user':'$user' '/home/$user/.config/systemd/user/waydroid-session.service'
loginctl enable-linger '$user'
systemctl start 'user@$uid.service' 2>/dev/null || true
runuser -u '$user' -- env XDG_RUNTIME_DIR=/run/user/$uid systemctl --user daemon-reload
runuser -u '$user' -- env XDG_RUNTIME_DIR=/run/user/$uid systemctl --user enable --now waydroid-session.service
"@
            $r = Invoke-RootScript -DistroName $DistroName -ScriptText $scriptText -Capture
            if ($r.Code -ne 0) { throw "Не удалось установить сервис сессии: $($r.Err)" }
            Write-Ok 'Сервис сессии установлен и запущен'
        }
    } else {
        Write-Ok 'Сервис сессии уже установлен'
    }

    # start and wait
    if (-not $DryRun) {
        Write-Step 'Ожидание сессии Waydroid'
        $session = Get-SessionState $DistroName
        if ($session.Session -ne 'RUNNING') {
            $uid = $session.Uid
            $user = $session.User
            $scriptText = @"
systemctl restart waydroid-container.service 2>/dev/null || systemctl start waydroid-container.service 2>/dev/null || true
systemctl start 'user@$uid.service' 2>/dev/null || true
runuser -u '$user' -- env XDG_RUNTIME_DIR=/run/user/$uid systemctl --user restart waydroid-session.service 2>/dev/null || true
"@
            [void](Invoke-RootScript -DistroName $DistroName -ScriptText $scriptText -Capture)
        }
        $running = $false
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 2
            $session = Get-SessionState $DistroName
            if ($session.Session -eq 'RUNNING') { $running = $true; break }
        }
        if ($running) { Write-Ok 'Сессия Waydroid запущена' }
        else {
            Write-Warn 'Сессия не запустилась за 2 минуты.'
            Write-Info 'Проверьте: wsl -d <distro> -- waydroid status; journalctl --user -u waydroid-session'
        }
    }

    # ADB
    Write-Step 'Подключение ADB'
    if ($DryRun) {
        Write-Info 'Будет скачан platform-tools (если нужно) и выполнен adb connect'
    } else {
        if (-not (Find-Adb)) { [void](Install-Adb) }
        $serial = $script:AdbSerial
        $session = Get-SessionState $DistroName
        if ($session.Session -eq 'RUNNING') {
            try { Enable-WindowsAdbKey $DistroName; Write-Ok 'Ключ Windows-ADB авторизован' }
            catch { Write-Warn $_.Exception.Message }
        }
        $ipScript = "export XDG_RUNTIME_DIR=/run/user/$($session.Uid); export WAYLAND_DISPLAY=wayland-0; export DISPLAY=:0; waydroid status 2>/dev/null | sed -n 's/^IP address:[[:space:]]*//p'"
        $ipLine = Invoke-WslCapture @('-d', $DistroName, '--', 'bash', '-c', (ConvertTo-BashCommand $ipScript)) 60
        $ip = $ipLine.Out.Trim()
        if ($ip -and $ip -ne 'UNKNOWN') { $serial = "${ip}:5555" }
        $adb = Get-AdbState $serial
        for ($i = 0; $i -lt 2 -and -not $adb.Online; $i++) {
            Start-Sleep -Seconds 3
            $adb = Get-AdbState $serial
        }
        if ($adb.Online) {
            Write-Ok "ADB подключён: $serial"
            Save-ManagerConfig $DistroName $serial
        } else {
            Write-Warn "ADB пока не ответил на $serial."
            Write-Info 'Он подключится автоматически при первом запуске приложения.'
            Save-ManagerConfig $DistroName $serial
        }
    }

    Write-Host ''
    Write-Host 'Готово. Перезапустите Winoid.' -ForegroundColor Green
    Show-Status $DistroName | Out-Null
}

function Show-Menu([string]$DistroName) {
    while ($true) {
        Write-Host ''
        Write-Host 'Winoid — настройка Android' -ForegroundColor White
        Write-Host '1  Проверить бэкенд'
        Write-Host '2  Настроить / восстановить'
        Write-Host '3  Открыть инструкцию в браузере'
        Write-Host '0  Выход'
        $choice = Read-Host 'Выбор'
        switch ($choice) {
            '1' { Show-Status $DistroName | Out-Null }
            '2' {
                try { Install-Backend $DistroName }
                catch { Write-Host ''; Write-Fail $_.Exception.Message; Write-Log ("ERROR " + $_.Exception.Message) }
                $DistroName = Resolve-Distro
            }
            '3' { Start-Process $script:ReadmeUrl; Write-Info 'Открыл README в браузере.' }
            '0' { return }
            default { Write-Warn 'Нет такого пункта.' }
        }
    }
}

Write-Host ''
Write-Host '========================================' -ForegroundColor DarkGray
Write-Host ' Winoid: настройка Android-бэкенда' -ForegroundColor White
Write-Host '========================================' -ForegroundColor DarkGray
Write-Log "START mode=$Mode distro=$Distro yes=$Yes dryrun=$DryRun"

$exitCode = 0
try {
    $resolved = Resolve-Distro
    if ($Mode -eq 'Check') {
        $ready = Show-Status $resolved
        if (-not $ready) { $exitCode = 1 }
    } elseif ($Mode -eq 'Install') {
        Install-Backend $resolved
    } else {
        Show-Menu $resolved
    }
} catch {
    Write-Host ''
    Write-Fail $_.Exception.Message
    Write-Log ("ERROR " + $_.Exception.Message)
    $exitCode = 1
}

if ($Mode -ne 'Menu' -and -not [Console]::IsInputRedirected) {
    Write-Host ''
    [void](Read-Host 'Нажмите Enter, чтобы закрыть окно')
}
exit $exitCode
