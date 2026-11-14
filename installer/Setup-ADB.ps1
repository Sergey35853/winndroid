$ErrorActionPreference = 'Stop'

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
                    [System.IO.File]::WriteAllText($wslConfig, ($out -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
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

$root = Initialize-WinoidRoot
$logPath = Join-Path $root 'setup-adb.log'
if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }

function Write-Log([string]$text) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $text
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

try {
    $dest = Join-Path $root 'platform-tools'
    $adb = Join-Path $dest 'adb.exe'
    if (Test-Path -LiteralPath $adb) {
        Write-Log 'platform-tools already installed'
        exit 0
    }

    Write-Log 'downloading platform-tools-latest-windows.zip'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $zip = Join-Path $env:TEMP 'winoid-platform-tools.zip'
    Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile $zip -UseBasicParsing

    $tmp = Join-Path $env:TEMP ('winoid-pt-' + [Guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $src = Join-Path $tmp 'platform-tools'
    if (-not (Test-Path -LiteralPath (Join-Path $src 'adb.exe'))) {
        throw 'adb.exe was not found in the downloaded archive'
    }

    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Move-Item -LiteralPath $src -Destination $dest
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Write-Log 'platform-tools installed successfully'
    exit 0
} catch {
    Write-Log ("error: " + $_.Exception.Message)
    exit 1
}
