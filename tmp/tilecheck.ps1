param([string]$dir)
Add-Type -AssemblyName System.Drawing
$files = Get-ChildItem -LiteralPath $dir -Filter *.png -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 6
if (-not $files) { "no png in $dir"; exit }
foreach ($f in $files) {
    $bmp = [System.Drawing.Bitmap]::FromFile($f.FullName)
    $w = $bmp.Width; $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle(0,0,$w,$h)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $data.Stride
    $bytes = [byte[]]::new($stride * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    $bmp.UnlockBits($data)
    $bmp.Dispose()
    "=== $($f.Name)  ${w}x${h} ==="
    $out = @()
    for ($by = 0; $by -lt [math]::Floor($h / 32); $by++) {
        for ($bx = 0; $bx -lt [math]::Floor($w / 32); $bx++) {
            $t = 0.0; $b2 = 0.0
            for ($y = 0; $y -lt 32; $y++) {
                for ($x = 0; $x -lt 32; $x++) {
                    $i = ($by * 32 + $y) * $stride + ($bx * 32 + $x) * 4
                    $lum = ($bytes[$i] + $bytes[$i+1] + $bytes[$i+2]) / 3.0
                    if ($y -lt 16) { $t += $lum } else { $b2 += $lum }
                }
            }
            $top = $t / 512.0; $bot = $b2 / 512.0
            $out += [pscustomobject]@{ bx = $bx; by = $by; diff = [math]::Round([math]::Abs($top - $bot),1); top = [math]::Round($top,1); bot = [math]::Round($bot,1) }
        }
    }
    "  blocks=$($out.Count)  avgHalfDiff=" + [math]::Round((($out | Measure-Object diff -Average).Average),2)
    $out | Sort-Object diff -Descending | Select-Object -First 6 | ForEach-Object {
        "  block(x={0},y={1})  top16={2}  bot16={3}  diff={4}" -f $_.bx, $_.by, $_.top, $_.bot, $_.diff
    }
}
