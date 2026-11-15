param(
    [string]$Out = (Join-Path $PSScriptRoot '..\assets\android.ico'),
    [string]$Preview = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function New-RoundedRect([float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    if ($d -gt $w) { $d = $w }
    if ($d -gt $h) { $d = $h }
    $p.AddArc(0, 0, $d, $d, 180, 90)
    $p.AddArc($w - $d, 0, $d, $d, 270, 90)
    $p.AddArc($w - $d, $h - $d, $d, $d, 0, 90)
    $p.AddArc(0, $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-IconBitmap([int]$s) {
    $bmp = New-Object System.Drawing.Bitmap $s, $s, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    # four squares, like the Windows Start button
    $m = $s * 0.055
    $gap = $s * 0.045
    $q = ($s - 2 * $m - $gap) / 2
    $r = [Math]::Max(1.0, $q * 0.14)
    $colors = @(
        [System.Drawing.Color]::FromArgb(255, 76, 154, 255),
        [System.Drawing.Color]::FromArgb(255, 61, 126, 255),
        [System.Drawing.Color]::FromArgb(255, 47, 107, 234),
        [System.Drawing.Color]::FromArgb(255, 36, 87, 197)
    )
    $positions = @(
        [pscustomobject]@{ X = $m; Y = $m },
        [pscustomobject]@{ X = ($m + $q + $gap); Y = $m },
        [pscustomobject]@{ X = $m; Y = ($m + $q + $gap) },
        [pscustomobject]@{ X = ($m + $q + $gap); Y = ($m + $q + $gap) }
    )
    for ($i = 0; $i -lt 4; $i++) {
        $path = New-RoundedRect $q $q $r
        $mt = New-Object System.Drawing.Drawing2D.Matrix
        $mt.Translate([float]$positions[$i].X, [float]$positions[$i].Y)
        $path.Transform($mt)
        $mt.Dispose()
        $brush = New-Object System.Drawing.SolidBrush $colors[$i]
        $g.FillPath($brush, $path)
        $brush.Dispose()
        $path.Dispose()
    }

    # android robot in front
    $white = [System.Drawing.Brushes]::White
    $dark = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 23, 58, 107))

    $head = New-Object System.Drawing.Drawing2D.GraphicsPath
    $hr = New-Object System.Drawing.RectangleF ($s * 0.28), ($s * 0.22), ($s * 0.44), ($s * 0.44)
    $head.AddArc($hr, 180, 180)
    $head.CloseFigure()
    $g.FillPath($white, $head)

    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ([Math]::Max(1.0, $s * 0.028))
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawLine($pen, ($s * 0.35), ($s * 0.25), ($s * 0.30), ($s * 0.16))
    $g.DrawLine($pen, ($s * 0.65), ($s * 0.25), ($s * 0.70), ($s * 0.16))

    if ($s -ge 24) {
        $eye = [Math]::Max(0.8, $s * 0.021)
        $g.FillEllipse($dark, ($s * 0.39 - $eye), ($s * 0.35 - $eye), ($eye * 2), ($eye * 2))
        $g.FillEllipse($dark, ($s * 0.61 - $eye), ($s * 0.35 - $eye), ($eye * 2), ($eye * 2))
    }

    $body = New-RoundedRect ($s * 0.34) ($s * 0.17) ([Math]::Max(1.5, $s * 0.035))
    $mt = New-Object System.Drawing.Drawing2D.Matrix
    $mt.Translate($s * 0.33, $s * 0.50)
    $body.Transform($mt)
    $mt.Dispose()
    $g.FillPath($white, $body)

    $armL = New-RoundedRect ($s * 0.07) ($s * 0.14) ([Math]::Max(1.5, $s * 0.034))
    $mt = New-Object System.Drawing.Drawing2D.Matrix
    $mt.Translate($s * 0.23, $s * 0.49)
    $armL.Transform($mt)
    $mt.Dispose()
    $g.FillPath($white, $armL)

    $armR = New-RoundedRect ($s * 0.07) ($s * 0.14) ([Math]::Max(1.5, $s * 0.034))
    $mt = New-Object System.Drawing.Drawing2D.Matrix
    $mt.Translate($s * 0.70, $s * 0.49)
    $armR.Transform($mt)
    $mt.Dispose()
    $g.FillPath($white, $armR)

    $legL = New-RoundedRect ($s * 0.07) ($s * 0.12) ([Math]::Max(1.5, $s * 0.034))
    $mt = New-Object System.Drawing.Drawing2D.Matrix
    $mt.Translate($s * 0.37, $s * 0.69)
    $legL.Transform($mt)
    $mt.Dispose()
    $g.FillPath($white, $legL)

    $legR = New-RoundedRect ($s * 0.07) ($s * 0.12) ([Math]::Max(1.5, $s * 0.034))
    $mt = New-Object System.Drawing.Drawing2D.Matrix
    $mt.Translate($s * 0.56, $s * 0.69)
    $legR.Transform($mt)
    $mt.Dispose()
    $g.FillPath($white, $legR)

    $pen.Dispose(); $head.Dispose(); $body.Dispose()
    $armL.Dispose(); $armR.Dispose(); $legL.Dispose(); $legR.Dispose(); $dark.Dispose(); $g.Dispose()
    return $bmp
}

if ($Preview) {
    $b = New-IconBitmap 256
    $b.Save($Preview, [System.Drawing.Imaging.ImageFormat]::Png)
    $b.Dispose()
    "preview: $Preview"
}

$sizes = @(16, 24, 32, 48, 64, 128, 256)
$pngs = @()
foreach ($s in $sizes) {
    $bmp = New-IconBitmap $s
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngs += ,$ms.ToArray()
    $ms.Dispose(); $bmp.Dispose()
}

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter $ms
$bw.Write([UInt16]0)
$bw.Write([UInt16]1)
$bw.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]
    $bw.Write([Byte]$(if ($s -ge 256) { 0 } else { $s }))
    $bw.Write([Byte]$(if ($s -ge 256) { 0 } else { $s }))
    $bw.Write([Byte]0)
    $bw.Write([Byte]0)
    $bw.Write([UInt16]1)
    $bw.Write([UInt16]32)
    $bw.Write([UInt32]$pngs[$i].Length)
    $bw.Write([UInt32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($png in $pngs) { $bw.Write($png) }
$bw.Flush()
$dir = Split-Path -Parent $Out
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
[System.IO.File]::WriteAllBytes($Out, $ms.ToArray())
$bw.Dispose(); $ms.Dispose()
"wrote $Out ($((Get-Item -LiteralPath $Out).Length) bytes)"
