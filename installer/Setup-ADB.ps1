$ErrorActionPreference = 'Stop'

$root = Join-Path $env:LOCALAPPDATA 'Winndroid'
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
    $zip = Join-Path $env:TEMP 'winndroid-platform-tools.zip'
    Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile $zip -UseBasicParsing

    $tmp = Join-Path $env:TEMP ('winndroid-pt-' + [Guid]::NewGuid().ToString('N'))
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
