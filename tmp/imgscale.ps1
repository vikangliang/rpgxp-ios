param([string]$src)
Add-Type -AssemblyName System.Drawing

$orig = [System.Drawing.Bitmap]::FromFile($src)
"orig = $($orig.Width)x$($orig.Height)"

# iOS 实际呈现尺寸（来自日志: scSize=1104x828, scOffset=344,0）
$tw = 1104; $th = 828

function Analyze-Image([System.Drawing.Bitmap]$bmp, [string]$tag) {
    $w = $bmp.Width; $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle(0,0,$w,$h)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $data.Stride
    $bytes = [byte[]]::new($stride * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    $bmp.UnlockBits($data)

    $rows = @()
    for ($y = 1; $y -lt $h; $y++) {
        $off = $y * $stride; $offp = ($y - 1) * $stride
        $changed = 0
        for ($x = 0; $x -lt $w; $x++) {
            $i = $off + $x * 4; $ip = $offp + $x * 4
            $d = [math]::Abs([int]$bytes[$i]   - [int]$bytes[$ip])   +
                 [math]::Abs([int]$bytes[$i+1] - [int]$bytes[$ip+1]) +
                 [math]::Abs([int]$bytes[$i+2] - [int]$bytes[$ip+2])
            if ($d -gt 24) { $changed++ }
        }
        $rows += ,@($y, $changed)
    }
    $strong = @($rows | Where-Object { $_[1] -ge $w * 0.9 })
    $half   = @($rows | Where-Object { $_[1] -ge $w * 0.5 })
    "$tag  size=${w}x${h}  strong(>=90%w)=$($strong.Count)  half(>=50%w)=$($half.Count)  total=$($rows.Count)"
    "  strong y list (first 40): " + (($strong | Select-Object -First 40 | ForEach-Object { $_[0] }) -join ',')
}

Analyze-Image $orig "orig"

foreach ($mode in @('Nearest','Bicubic')) {
    $dst = New-Object System.Drawing.Bitmap($tw, $th)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    if ($mode -eq 'Nearest') {
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    } else {
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    }
    $g.DrawImage($orig, 0, 0, $tw, $th)
    $g.Dispose()
    $half = New-Object System.Drawing.Bitmap([int]($tw/2), [int]($th/2))
    $g2 = [System.Drawing.Graphics]::FromImage($half)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $g2.DrawImage($dst, 0, 0, $half.Width, $half.Height)
    $g2.Dispose()
    Analyze-Image $half "scaled_$mode"
    $dst.Save((Join-Path $env:TEMP "bug2_full_$mode.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    "  full-size saved: $(Join-Path $env:TEMP "bug2_full_$mode.png")"
    $half.Dispose(); $dst.Dispose()
}
$orig.Dispose()
