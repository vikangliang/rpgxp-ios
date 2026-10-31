param([string]$tile)
Add-Type -AssemblyName System.Drawing

$src = [System.Drawing.Bitmap]::FromFile($tile)
$blk = New-Object System.Drawing.Bitmap(32,32)
$g = [System.Drawing.Graphics]::FromImage($blk)
$g.DrawImage($src, (New-Object System.Drawing.Rectangle(0,0,32,32)), (New-Object System.Drawing.Rectangle(0,0,32,32)), [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose()

$scale = 8
$big = New-Object System.Drawing.Bitmap(($scale*32), ($scale*32))
$g2 = [System.Drawing.Graphics]::FromImage($big)
$g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
$g2.DrawImage($blk, 0, 0, ($scale*32), ($scale*32))
$g2.Dispose()

$outW = 32 + 16 + ($scale*32)
$out = New-Object System.Drawing.Bitmap($outW, ($scale*32))
$g3 = [System.Drawing.Graphics]::FromImage($out)
$g3.Clear([System.Drawing.Color]::FromArgb(20,20,24))
$g3.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g3.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
$g3.DrawImage($blk, 0, 0, 32, 32)
$g3.DrawImage($big, 48, 0)
$g3.Dispose()

$dest = "c:\Users\Lenovo\CodeBuddy\20260908220535\tmp\autotile_compare.png"
$out.Save($dest, [System.Drawing.Imaging.ImageFormat]::Png)
"saved: $dest  (left = 32x32 tile at 1:1, right = same tile x$scale nearest-neighbour)"
$out.Dispose(); $big.Dispose(); $blk.Dispose(); $src.Dispose()
