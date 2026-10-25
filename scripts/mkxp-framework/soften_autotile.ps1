param([string]$Dir, [string]$Out = "", [int]$K = 8)
# 把 autotile 素材里 32x32 块的"上半/下半"明暗硬边柔化成渐变过渡。
# 根因: 每 32px 一条横线来自素材自带的 16px 子块明暗差
#       (Graphics/Autotiles/Land.png 每块上半 ~126 / 下半 ~158, 差 31)。
#       桌面 RPG Maker 靠 Windows DPI 双线性插值把它抹平, 所以看不出来。
# 本脚本在素材层面直接做渐变过渡, 任何缩放下都没有硬边。
# 不覆盖原文件: 结果输出到同级 Autotiles_soft 目录, 满意后自行替换。
# 用法:
#   powershell -File soften_autotile.ps1 -Dir "<游戏目录>\Graphics\Autotiles" -K 8
# 实测(Land.png, 同一块的上下半亮度差): 原始 31.6 -> K=4: 26.9 -> K=8: 23.3 -> K=16: 15.8
# K 越大过渡越宽、硬边越弱, 但画面观感变化也越大(K=16 时上半会明显偏亮)。
Add-Type -AssemblyName System.Drawing
if (-not $Out) { $Out = Join-Path (Split-Path $Dir -Parent) "Autotiles_soft" }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$files = Get-ChildItem -LiteralPath $Dir -Filter *.png -ErrorAction SilentlyContinue
if (-not $files) { "no png in $Dir"; exit 1 }
foreach ($f in $files) {
    $bmp = [System.Drawing.Bitmap]::FromFile($f.FullName)
    $w = $bmp.Width; $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle(0,0,$w,$h)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $st = $data.Stride
    $px = [byte[]]::new($st * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $px, 0, $px.Length)
    $bmp.UnlockBits($data)
    $up = New-Object byte[] 128
    $dn = New-Object byte[] 128
    for ($by = 0; $by -lt [math]::Floor($h/32); $by++) {
        for ($bx = 0; $bx -lt [math]::Floor($w/32); $bx++) {
            for ($i = 0; $i -lt $K; $i++) {
                $yu = $by*32 + (16-$K+$i); $yd = $by*32 + 16 + $i
                [Array]::Copy($px, $yu*$st + $bx*32*4, $up, 0, 128)
                [Array]::Copy($px, $yd*$st + $bx*32*4, $dn, 0, 128)
                $t = ($i + 1) / ($K + 1.0)
                for ($j = 0; $j -lt 128; $j++) {
                    if ($j % 4 -eq 3) { continue }
                    $a = $up[$j]; $b = $dn[$j]
                    $px[$yu*$st + $bx*32*4 + $j] = [byte][math]::Max(0,[math]::Min(255,[int][math]::Round($a + ($b-$a)*$t*0.5)))
                    $px[$yd*$st + $bx*32*4 + $j] = [byte][math]::Max(0,[math]::Min(255,[int][math]::Round($b + ($a-$b)*(1-$t)*0.5)))
                }
            }
        }
    }
    $outBmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($outBmp)
    $g.DrawImage($bmp, 0, 0)
    $g.Dispose(); $bmp.Dispose()
    $rect2 = New-Object System.Drawing.Rectangle(0,0,$w,$h)
    $d2 = $outBmp.LockBits($rect2, [System.Drawing.Imaging.ImageLockMode]::ReadWrite, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    [System.Runtime.InteropServices.Marshal]::Copy($px, 0, $d2.Scan0, $px.Length)
    $outBmp.UnlockBits($d2)
    $outBmp.Save((Join-Path $Out $f.Name), [System.Drawing.Imaging.ImageFormat]::Png)
    $outBmp.Dispose()
    "softened: $($f.Name)"
}
"done -> $Out"
