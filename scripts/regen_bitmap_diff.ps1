# Regenerate the bitmap.cpp diff section of framework-entry.patch:
#  1) extract current bitmap.cpp section, apply to pristine copy via git apply
#  2) edit: CAP 64->128MB; get() rebuilds mega surfaces from cached pixels;
#     put() no longer gated by maxTexSize (+oversized-entry guard)
#  3) git diff --no-index -> replace section; validate whole patch
$ErrorActionPreference = "Stop"
$patchPath = (Resolve-Path "$PSScriptRoot\mkxp-framework\framework-entry.patch").Path
$pristine  = (Resolve-Path "$PSScriptRoot\..\deps\mkxp-z-src\src\display\bitmap.cpp").Path
$srcDir    = (Resolve-Path "$PSScriptRoot\..\deps\mkxp-z-src").Path

$work = Join-Path $env:TEMP "bmpregen"
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path "$work\orig\src\display" | Out-Null
New-Item -ItemType Directory -Path "$work\new\src\display"  | Out-Null
Copy-Item $pristine "$work\orig\src\display\bitmap.cpp"
Copy-Item $pristine "$work\new\src\display\bitmap.cpp"

# ---- extract bitmap.cpp section ----
$pl = ([IO.File]::ReadAllText($patchPath)).Replace("`r`n","`n").Split([char]10)
$i1 = -1; $i2 = $pl.Count
for ($i=0; $i -lt $pl.Count; $i++) {
  if ($pl[$i] -match "^diff --git " -and $pl[$i] -match "bitmap\.cpp") { if ($i1 -lt 0) { $i1 = $i } }
  elseif ($i1 -ge 0 -and $pl[$i] -match "^diff --git ") { $i2 = $i; break }
}
if ($i1 -lt 0) { Write-Output "ERROR: bitmap section not found"; exit 1 }
$sec = $pl[$i1..($i2-1)] -join "`n"
[IO.File]::WriteAllText("$work\bitmap_section.patch", $sec + "`n")

# ---- apply current section to the new copy ----
$r = Start-Process -FilePath "git" -ArgumentList "apply `"$work\bitmap_section.patch`"" -WorkingDirectory "$work\new" -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\ba_out.txt" -RedirectStandardError "$env:TEMP\ba_err.txt"
if ($r.ExitCode -ne 0) { Write-Output "ERROR: git apply section rc=$($r.ExitCode)"; Get-Content "$env:TEMP\ba_err.txt" | Select-Object -First 6; exit 1 }
Write-Output "section applied to pristine copy"

# ---- edit the patched file ----
$f = "$work\new\src\display\bitmap.cpp"
$s = [IO.File]::ReadAllText($f).Replace("`r`n","`n")

$s = $s.Replace("static const int64_t CAP_BYTES = 64LL * 1024 * 1024;",
                "static const int64_t CAP_BYTES = 128LL * 1024 * 1024;")

$oldGet = @"
    {
        int cw = 0, ch = 0;
        std::vector<uint8_t> cpx;
        if (g_decodedPixelCache.get(filename, cw, ch, cpx))
        {
            if (cw <= glState.caps.maxTexSize && ch <= glState.caps.maxTexSize)
            {
                p = new BitmapPrivate(this);
                TEXFBO tex = shState->texPool().request(cw, ch);
                p->gl = tex;
                TEX::bind(p->gl.tex);
                TEX::uploadImage(cw, ch, cpx.data(), GL_RGBA);
                p->addTaintedArea(rect());
                return;
            }
        }
    }
"@
$newGet = @"
    {
        int cw = 0, ch = 0;
        std::vector<uint8_t> cpx;
        if (g_decodedPixelCache.get(filename, cw, ch, cpx))
        {
            p = new BitmapPrivate(this);
            if (cw > glState.caps.maxTexSize || ch > glState.caps.maxTexSize)
            {
                /* Mega-size cached asset (e.g. 256x38660 tileset): rebuild
                 * the mega surface from cached pixels - skips PNG decode. */
                SDL_Surface *ms = SDL_CreateRGBSurfaceWithFormat(0, cw, ch, 32, SDL_PIXELFORMAT_ABGR8888);
                for (int y = 0; y < ch; ++y)
                    memcpy((uint8_t*)ms->pixels + (size_t)y * ms->pitch,
                           cpx.data() + (size_t)y * cw * 4, (size_t)cw * 4);
                p->megaSurface = ms;
                SDL_SetSurfaceBlendMode(p->megaSurface, SDL_BLENDMODE_NONE);
            }
            else
            {
                TEXFBO tex = shState->texPool().request(cw, ch);
                p->gl = tex;
                TEX::bind(p->gl.tex);
                TEX::uploadImage(cw, ch, cpx.data(), GL_RGBA);
                p->addTaintedArea(rect());
            }
            return;
        }
    }
"@
$oldGet = $oldGet.Replace("`r`n","`n"); $newGet = $newGet.Replace("`r`n","`n")
if (-not $s.Contains($oldGet)) { Write-Output "ERROR: get-block anchor missing"; exit 1 }
$s = $s.Replace($oldGet, $newGet.TrimEnd("`r","`n"))

$oldPut = @"
    if (imgSurf->w <= glState.caps.maxTexSize && imgSurf->h <= glState.caps.maxTexSize)
    {
        g_decodedPixelCache.put(filename, imgSurf->w, imgSurf->h,
            (const uint8_t*)imgSurf->pixels,
            (size_t)imgSurf->w * imgSurf->h * 4);
    }
"@
$newPut = @"
    g_decodedPixelCache.put(filename, imgSurf->w, imgSurf->h,
        (const uint8_t*)imgSurf->pixels,
        (size_t)imgSurf->w * imgSurf->h * 4);
"@
$oldPut = $oldPut.Replace("`r`n","`n"); $newPut = $newPut.Replace("`r`n","`n")
if (-not $s.Contains($oldPut)) { Write-Output "ERROR: put-gate anchor missing"; exit 1 }
$s = $s.Replace($oldPut, $newPut.TrimEnd("`r","`n"))

# oversized-entry guard inside put() (single assets above cap are never cached)
$oldGuard = "        int64_t add = (int64_t)n;`n"
$newGuard = "        int64_t add = (int64_t)n;`n        if (add > CAP_BYTES) { miss++; ops++; SDL_UnlockMutex(mut); return; }`n"
if (-not $s.Contains($oldGuard)) { Write-Output "ERROR: put guard anchor missing"; exit 1 }
$s = $s.Replace($oldGuard, $newGuard)

[IO.File]::WriteAllText($f, $s, (New-Object System.Text.UTF8Encoding($false)))
Write-Output "edits applied"

# ---- regenerate diff ----
$diffOut = "$env:TEMP\bitmap.diff"
$r = Start-Process -FilePath "git" -ArgumentList "diff --no-index --src-prefix=a/ --dst-prefix=b/ `"$work\orig\src\display\bitmap.cpp`" `"$work\new\src\display\bitmap.cpp`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput $diffOut -RedirectStandardError "$env:TEMP\gd_err.txt"
if ($r.ExitCode -ne 1) { Write-Output "ERROR: git diff rc=$($r.ExitCode)"; Get-Content "$env:TEMP\gd_err.txt"; exit 1 }
$d = [IO.File]::ReadAllText($diffOut).Replace("`r`n","`n")
$of = "$work\orig\src\display\bitmap.cpp".Replace("\","\\")
$nf = "$work\new\src\display\bitmap.cpp".Replace("\","\\")
$d = $d.Replace('"a/' + $of + '"', 'a/src/display/bitmap.cpp').Replace('"b/' + $nf + '"', 'b/src/display/bitmap.cpp')
$d = $d.Replace('a/' + $of, 'a/src/display/bitmap.cpp').Replace('b/' + $nf, 'b/src/display/bitmap.cpp')
$secLines = $d.Split([char]10) | Where-Object { $_ -notmatch "^(index |old mode|new mode)" }

# ---- splice ----
$newPatch = @()
$newPatch += $pl[0..($i1-1)]
$newPatch += $secLines
$newPatch += $pl[$i2..($pl.Count-1)]
[IO.File]::WriteAllText($patchPath, (($newPatch -join "`n")), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "bitmap.cpp section regenerated"

# ---- validate ----
$r = Start-Process -FilePath "git" -ArgumentList "apply --check `"$patchPath`"" -WorkingDirectory $srcDir -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\ga_out.txt" -RedirectStandardError "$env:TEMP\ga_err.txt"
Write-Output "git apply --check rc=$($r.ExitCode)"
Get-Content "$env:TEMP\ga_err.txt" -ErrorAction SilentlyContinue | Select-Object -First 8
if ($r.ExitCode -ne 0) { exit 2 }
