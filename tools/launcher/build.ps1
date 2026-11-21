$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
$src = Join-Path $PSScriptRoot 'WinoidLauncher.cs'
$out = Join-Path $root 'WinoidLauncher.exe'
& $csc /nologo /target:winexe /optimize+ /r:System.Windows.Forms.dll /out:$out $src
if ($LASTEXITCODE -ne 0) { throw "csc failed with $LASTEXITCODE" }
"wrote $out ($((Get-Item -LiteralPath $out).Length) bytes)"
