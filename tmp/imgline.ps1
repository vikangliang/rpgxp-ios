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

$res = @()
for ($y = 1; $y -lt $h; $y++) {
    $off = $y * $stride; $offp = ($y - 1) * $stride
    $changed = 0; $sum = 0.0; $maxd = 0
    for ($x = 0; $x -lt $w; $x++) {
        $i = $off + $x * 4; $ip = $offp + $x * 4
        $d = [math]::Abs([int]$bytes[$i] - [int]$bytes[$ip]) + [math]::Abs([int]$bytes[$i+1] - [int]$bytes[$ip+1]) + [math]::Abs([int]$bytes[$i+2] - [int]$bytes[$ip+2])
        $sum += $d
        if ($d -gt $maxd) { $maxd = $d }
        if ($d -gt 24) { $changed++ }
    }
    $res += [pscustomobject]@{ y = $y; changed = $changed; avg = $sum / $w; maxd = $maxd }
}

"=== A. changed 分布（贯穿型细线候选：changed 接近全宽） ==="
"rows changed >= 90% width : " + (@($res | Where-Object { $_.changed -ge $w * 0.9 }).Count)
"rows changed >= 50% width : " + (@($res | Where-Object { $_.changed -ge $w * 0.5 }).Count)
"rows changed == 0        : " + (@($res | Where-Object { $_.changed -eq 0 }).Count)
"avg of avg                : " + [math]::Round((($res | Measure-Object avg -Average).Average), 2)
"median of avg             : " + [math]::Round((($res | Sort-Object avg | Select-Object -Index ([int]($res.Count/2))).avg), 2)

"=== B. top 15 by changed ==="
$res | Sort-Object changed -Descending | Select-Object -First 15 | ForEach-Object {
    "y={0,3} changed={1,4}/{2} avg={3,7:N2} max={4,4} y%32={5} y%2={6}" -f $_.y,$_.changed,$w,$_.avg,$_.maxd,($_.y%32),($_.y%2)
}

"=== C. top 12 by avg ==="
$res | Sort-Object avg -Descending | Select-Object -First 12 | ForEach-Object {
    "y={0,3} changed={1,4}/{2} avg={3,7:N2} max={4,4} y%32={5} y%2={6}" -f $_.y,$_.changed,$w,$_.avg,$_.maxd,($_.y%32),($_.y%2)
}

"=== D. 按 y%2 分组的 avg 均值（若某组显著更高 -> 隔行伪影） ==="
foreach ($par in 0,1) {
    $g = $res | Where-Object { ($_.y % 2) -eq $par }
    "y%2={0}: n={1} avgMean={2:N2}" -f $par, $g.Count, (($g | Measure-Object avg -Average).Average)
}

"=== E. 逐行 avg 全表（每 8 行取样，找周期性） ==="
$res | Where-Object { ($_.y % 8) -eq 0 } | ForEach-Object {
    "y={0,3} avg={1,7:N2} changed={2,4}" -f $_.y,$_.avg,$_.changed
}
