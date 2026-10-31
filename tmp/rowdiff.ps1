# Bug2 取证：对双人 linen 图片做逐行像素差分析，定位"横线"所在 y
# 用法: powershell -ExecutionPolicy Bypass -File rowdiff.ps1
$dir = "C:\Users\Lenovo\AppData\Local\CodeBuddyExtension\Data\712d2785-fab1-49c8-a013-828005c17da3"
$f = Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop |
     Where-Object { $_.Extension -in '.jpg', '.jpeg', '.png' } |
     Sort-Object LastWriteTime -Descending | Select-Object -First 1
$p = $f.FullName
"file = $($f.Name)"
"path = $p"
"len  = $($f.Length)"

Add-Type -AssemblyName System.Drawing
$bmp = [System.Drawing.Bitmap]::FromFile($p)
$w = $bmp.Width; $h = $bmp.Height
"size = ${w}x${h}"

$rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
$data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                      [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$stride = $data.Stride
$bytes = New-Object -TypeName 'System.Byte[]' -ArgumentList ($stride * $h)
[System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
$bmp.UnlockBits($data)
$bmp.Dispose()

$g = New-Object -TypeName 'System.Double[]' -ArgumentList ($w * $h)
for ($y = 0; $y -lt $h; $y++) {
  $off = $y * $stride
  for ($x = 0; $x -lt $w; $x++) {
    $i = $off + $x * 3
    $g[$y * $w + $x] = ($bytes[$i] + $bytes[$i + 1] + $bytes[$i + 2]) / 3.0
  }
}

$diff = New-Object -TypeName 'System.Double[]' -ArgumentList $h
for ($y = 1; $y -lt $h; $y++) {
  $s = 0.0
  for ($x = 0; $x -lt $w; $x++) {
    $s += [math]::Abs($g[$y * $w + $x] - $g[($y - 1) * $w + $x])
  }
  $diff[$y] = $s / $w
}

""
"--- top 15 rows by mean |row(y) - row(y-1)| ---"
(1..($h - 1) | Sort-Object { -$diff[$_] } | Select-Object -First 15) | ForEach-Object {
  "  y={0,4}  diff={1,8:N3}  y mod 32 = {2}" -f $_, $diff[$_], ($_ % 32)
}

""
"--- tile-edge vs non-edge (assume tile=32) ---"
$edge = @(); $non = @()
for ($y = 1; $y -lt $h; $y++) {
  if (($y % 32) -eq 0) { $edge += $diff[$y] } else { $non += $diff[$y] }
}
if ($edge.Count -gt 0 -and $non.Count -gt 0) {
  $ea = ($edge | Measure-Object -Average).Average
  $na = ($non | Measure-Object -Average).Average
  "  tile-edge rows (y%32==0): n={0} avg_diff={1:N3}" -f $edge.Count, $ea
  "  other rows             : n={0} avg_diff={1:N3}" -f $non.Count, $na
  "  ratio = {0:N3}   (>>1 表示错位集中在 tile 行边界)" -f ($ea / [math]::Max($na, 0.0001))
}

""
"--- all rows with diff above 2.5x global mean (candidate anomaly lines) ---"
$mean = ($diff[1..($h - 1)] | Measure-Object -Average).Average
$sd = [math]::Sqrt((($diff[1..($h - 1)] | ForEach-Object { ($_ - $mean) * ($_ - $mean) } | Measure-Object -Sum).Sum) / ($h - 1))
"  global mean={0:N3} sd={1:N3}" -f $mean, $sd
(1..($h - 1) | Where-Object { $diff[$_] -gt ($mean + 2.5 * $sd) } | Sort-Object { -$diff[$_] } | Select-Object -First 25) | ForEach-Object {
  "  y={0,4}  diff={1,8:N3}  y mod 32 = {2}" -f $_, $diff[$_], ($_ % 32)
}
