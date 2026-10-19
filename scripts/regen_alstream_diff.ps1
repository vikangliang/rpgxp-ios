# Regenerate the alstream.cpp diff section of framework-entry.patch using git
# diff --no-index (guaranteed well-formed). Replaces everything between
# 'diff --git a/src/audio/alstream.cpp' and 'diff --git a/src/audio/alstream.h'.
$ErrorActionPreference = "Stop"
$patchPath = Join-Path $PSScriptRoot "mkxp-framework\framework-entry.patch"
$srcFile   = Join-Path $PSScriptRoot "..\deps\mkxp-z-src\src\audio\alstream.cpp"
$tmp   = Join-Path $env:TEMP "alstream_orig.cpp"
$newf  = Join-Path $env:TEMP "alstream_new.cpp"

$nl = "`r`n"
if (-not ([IO.File]::ReadAllText($srcFile).Contains("`r`n"))) { $nl = "`n" }
$t = [char]9
$q = [char]34

# ---- build the modified copy ----
$s = [IO.File]::ReadAllText($srcFile)

$oldCtor = "      pitch(1.0f)" + $nl + "{"
$newCtor = "      pitch(1.0f), healRetries(0), lastHealTicks(0)" + $nl + "{"
if (-not $s.Contains($oldCtor)) { Write-Output "ERROR: ctor anchor missing"; exit 1 }
$s = $s.Replace($oldCtor, $newCtor)

$oldCS = "$t" + "if (!streamInited)" + $nl `
  + "$t" + $t + "return;" + $nl `
  + $nl `
  + "$t" + "/* If alSrc isn't playing, but we haven't" + $nl `
  + "$t" + " * exhausted the data source yet, we're just" + $nl `
  + "$t" + " * having a buffer underrun */" + $nl `
  + "$t" + "if (!sourceExhausted)" + $nl `
  + "$t" + $t + "return;" + $nl `
  + $nl `
  + "$t" + "if (AL::Source::getState(alSrc) == AL_PLAYING)" + $nl `
  + "$t" + $t + "return;" + $nl `
  + $nl `
  + "$t" + "stopStream();" + $nl `
  + "$t" + "state = Stopped;" + $nl `
  + "}"
$newCS = "$t" + "if (!streamInited)" + $nl `
  + "$t" + $t + "return;" + $nl `
  + $nl `
  + "$t" + "/* If streaming thread hasn't queued up" + $nl `
  + "$t" + " * buffers yet there's not point in querying" + $nl `
  + "$t" + " * the AL source */" + $nl `
  + "$t" + "/* Only a logically-Playing stream can die unexpectedly. Paused/Stopped" + $nl `
  + "$t" + " * tracks are explicitly managed (ME/jingle pause, user stop) and must" + $nl `
  + "$t" + " * NOT be restarted here: the previous unconditional heal restarted the" + $nl `
  + "$t" + " * BGM under a playing ME (jingle replaces BGM, repeated restarts) and" + $nl `
  + "$t" + " * looped finished non-looping tracks (device-verified 2026-10-19 via" + $nl `
  + "$t" + " * " + $q + "bgm heal attempt" + $q + " spam while alstate=AL_STOPPED). */" + $nl `
  + "$t" + "if (state != Playing)" + $nl `
  + "$t" + "{" + $nl `
  + "$t" + $t + "healRetries = 0;" + $nl `
  + "$t" + $t + "lastHealTicks = 0;" + $nl `
  + "$t" + $t + "return;" + $nl `
  + "$t" + "}" + $nl `
  + $nl `
  + "$t" + "ALenum s = AL::Source::getState(alSrc);" + $nl `
  + "$t" + "if (s == AL_PLAYING)" + $nl `
  + "$t" + "{" + $nl `
  + "$t" + $t + "healRetries = 0;" + $nl `
  + "$t" + $t + "lastHealTicks = 0;" + $nl `
  + "$t" + $t + "return;" + $nl `
  + "$t" + "}" + $nl `
  + $nl `
  + "$t" + "/* End of a non-looping track (data exhausted): stop cleanly. */" + $nl `
  + "$t" + "if (sourceExhausted)" + $nl `
  + "$t" + "{" + $nl `
  + "$t" + $t + "stopStream();" + $nl `
  + "$t" + $t + "state = Stopped;" + $nl `
  + "$t" + $t + "return;" + $nl `
  + "$t" + "}" + $nl `
  + $nl `
  + "$t" + "/* Playing but the AL source died before data end: transient underrun" + $nl `
  + "$t" + " * or the iOS audio-vacuum after an interruption/device invalidation." + $nl `
  + "$t" + " * Heal by restarting the stream, throttled to once per 2s, capped at" + $nl `
  + "$t" + " * 30 tries (~60s) so we keep retrying without busy-looping forever. */" + $nl `
  + "$t" + "if (healRetries >= 30)" + $nl `
  + "$t" + "{" + $nl `
  + "$t" + $t + "Debug() << " + $q + "rgss: bgm heal gave up after" + $q + " << healRetries;" + $nl `
  + "$t" + $t + "stopStream();" + $nl `
  + "$t" + $t + "state = Stopped;" + $nl `
  + "$t" + $t + "return;" + $nl `
  + "$t" + "}" + $nl `
  + "$t" + "uint32_t now = SDL_GetTicks();" + $nl `
  + "$t" + "if (now - lastHealTicks < 2000)" + $nl `
  + "$t" + $t + "return;" + $nl `
  + "$t" + "lastHealTicks = now;" + $nl `
  + "$t" + "healRetries++;" + $nl `
  + "$t" + "Debug() << " + $q + "rgss: bgm heal attempt" + $q + " << healRetries << " + $q + "alstate=" + $q + " << s;" + $nl `
  + "$t" + "/* Resume from the CURRENT decode position, not startOffset: an underrun" + $nl `
  + "$t" + " * must not restart the track from the beginning (the audible " + $q + "repeat" + $q + ")" + $nl `
  + "$t" + " * the user hears). queryOffset() is captured BEFORE stopStream() zeroes" + $nl `
  + "$t" + " * procFrames, so we continue seamlessly where playback died. */" + $nl `
  + "$t" + "float resumeOff = queryOffset();" + $nl `
  + "$t" + "stopStream();" + $nl `
  + "$t" + "startStream(resumeOff);" + $nl `
  + "}"
if (-not $s.Contains($oldCS)) { Write-Output "ERROR: checkStopped anchor missing"; exit 1 }
$s = $s.Replace($oldCS, $newCS)

[IO.File]::WriteAllText($tmp, [IO.File]::ReadAllText($srcFile), (New-Object System.Text.UTF8Encoding($false)))
[IO.File]::WriteAllText($newf, $s, (New-Object System.Text.UTF8Encoding($false)))

# ---- generate diff ----
$diffOut = "$env:TEMP\alstream.diff"
$r = Start-Process -FilePath "git" -ArgumentList "diff --no-index --src-prefix=a/ --dst-prefix=b/ `"$tmp`" `"$newf`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput $diffOut -RedirectStandardError "$env:TEMP\gd_err.txt"
if ($r.ExitCode -ne 1) { Write-Output "ERROR: git diff rc=$($r.ExitCode)"; Get-Content "$env:TEMP\gd_err.txt"; exit 1 }
$d = [IO.File]::ReadAllText($diffOut).Replace("`r`n", "`n")
$tmpFwd = $tmp.Replace("\", "\\")
$newFwd = $newf.Replace("\", "\\")
$d = $d.Replace('"a/' + $tmpFwd + '"', 'a/src/audio/alstream.cpp')
$d = $d.Replace('"b/' + $newFwd + '"', 'b/src/audio/alstream.cpp')
$d = $d.Replace('a/' + $tmpFwd, 'a/src/audio/alstream.cpp')
$d = $d.Replace('b/' + $newFwd, 'b/src/audio/alstream.cpp')
# drop the temp-file specific index/binary lines? keep as-is except paths
$sec = ($d.Split([char]10) | Where-Object { $_ -notmatch "^(index |old mode|new mode)" }) -join "`n"

# ---- splice into framework-entry.patch (line-based section bounds) ----
$pl = ([IO.File]::ReadAllText($patchPath)).Replace("`r`n","`n").Split([char]10)
$i1 = -1; $i2 = -1
for ($i=0; $i -lt $pl.Count; $i++) {
  if ($pl[$i] -match "^diff --git " -and $pl[$i] -match "alstream\.cpp") { if ($i1 -lt 0) { $i1 = $i } }
  if ($pl[$i] -match "^diff --git " -and $pl[$i] -match "alstream\.h" -and $i1 -ge 0 -and $i2 -lt 0) { $i2 = $i }
}
if ($i1 -lt 0 -or $i2 -lt 0 -or $i2 -le $i1) { Write-Output "ERROR: section markers not found (i1=$i1 i2=$i2)"; exit 1 }
$secLines = $sec.Split([char]10)
$newPatch = @()
$newPatch += $pl[0..($i1-1)]
$newPatch += $secLines
$newPatch += $pl[$i2..($pl.Count-1)]
[IO.File]::WriteAllText($patchPath, (($newPatch -join "`n")), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "alstream.cpp section regenerated (lines $i1..$i2 -> $($secLines.Count) lines)"

# ---- validate whole patch ----
$srcDir = (Resolve-Path (Join-Path $PSScriptRoot "..\deps\mkxp-z-src")).Path
$abs = (Resolve-Path $patchPath).Path
$r = Start-Process -FilePath "git" -ArgumentList "apply --check `"$abs`"" -WorkingDirectory $srcDir -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\ga_out.txt" -RedirectStandardError "$env:TEMP\ga_err.txt"
Write-Output "git apply --check rc=$($r.ExitCode)"
Get-Content "$env:TEMP\ga_err.txt" -ErrorAction SilentlyContinue | Select-Object -First 6
if ($r.ExitCode -ne 0) { exit 2 }
