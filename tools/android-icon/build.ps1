$ErrorActionPreference = 'Stop'
$sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$androidJar = Join-Path $sdk 'platforms\android-35\android.jar'
$buildTools = Join-Path $sdk 'build-tools\36.0.0'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$src = Join-Path $PSScriptRoot 'WinoidIcon.java'
$outDex = Join-Path $root 'assets\winoid-icon.dex'
$work = Join-Path $env:TEMP ('winoid-icon-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

& javac -source 8 -target 8 -classpath $androidJar -d $work $src 2>&1 | ForEach-Object { $_ }
if ($LASTEXITCODE -ne 0) { throw 'javac failed' }

& (Join-Path $buildTools 'd8.bat') --lib $androidJar --output $work (Join-Path $work 'WinoidIcon.class') 2>&1 | ForEach-Object { $_ }
if ($LASTEXITCODE -ne 0) { throw 'd8 failed' }

Copy-Item (Join-Path $work 'classes.dex') $outDex -Force
"wrote $outDex ($((Get-Item -LiteralPath $outDex).Length) bytes)"
Remove-Item $work -Recurse -Force
