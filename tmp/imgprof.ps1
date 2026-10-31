param([string]$src)
Add-Type -AssemblyName System.Drawing
$bmp = [System.Drawing.Bitmap]::FromFile($src)
$w = $bmp.Width; $h = $bmp.Height
"size = ${w}x${h}"
$rect = New-Object System.Drawing.Rectangle(0,0,$w,$h)
$data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$stride = $data.Stride
$bytes = [byte[]]::new($stride * $h)
[System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
$bmp.UnlockBits($data)
$bmp.Dispose()

# 垂直剖面：沿若干 x 列找亮度突变点（逐行精扫，只报突变）
$cols = @(230, 300, 380, 470, 560, 620)
foreach ($x in $cols) {
    if ($x -ge $w) { continue }
    "=== x=$x 垂直剖面突变点(与上一行差>12) ==="
    $pR = $bytes[50*$stride + $x*4]; $pG = $bytes[50*$stride + $x*4+1]; $pB = $bytes[50*$stride + $x*4+2]
    $hits = @()
    for ($y = 51; $y -lt $h - 2; $y++) {
        $i = $y*$stride + $x*4
        $r = $bytes[$i]; $g = $bytes[$i+1]; $b = $bytes[$i+2]
        $d = [math]::Abs($r-$pR) + [math]::Abs($g-$pG) + [math]::Abs($b-$pB)
        if ($d -gt 12) { $hits += ("y={0,3}(y%32={1,2}) rgb=({2},{3},{4}) d={5}" -f $y, ($y%32), $r, $g, $b, $d) }
        $pR = $r; $pG = $g; $pB = $b
    }
    "  突变点数 = $($hits.Count)"
    $hits | Select-Object -First 24 | ForEach-Object { "  $_" }
}
