# Fix the alstream.cpp section header paths (previous splice left quoted temp paths)
# then validate the whole patch with git apply --check.
$ErrorActionPreference = "Stop"
$patchPath = "$PSScriptRoot\mkxp-framework\framework-entry.patch"
$srcDir = (Resolve-Path "$PSScriptRoot\..\deps\mkxp-z-src").Path

$p = [IO.File]::ReadAllText($patchPath)
$p = $p.Replace('diff --git "a/C:\\Users\\Lenovo\\AppData\\Local\\Temp\\alstream_orig.cpp" "b/C:\\Users\\Lenovo\\AppData\\Local\\Temp\\alstream_new.cpp"',
                'diff --git a/src/audio/alstream.cpp b/src/audio/alstream.cpp')
$p = $p.Replace('--- "a/C:\\Users\\Lenovo\\AppData\\Local\\Temp\\alstream_orig.cpp"',
                '--- a/src/audio/alstream.cpp')
$p = $p.Replace('+++ "b/C:\\Users\\Lenovo\\AppData\\Local\\Temp\\alstream_new.cpp"',
                '+++ b/src/audio/alstream.cpp')
# drop stale index line for the temp-file diff (blob hashes refer to temp files)
$p = $p -replace "(?m)^index [0-9a-f]+\.\.56ea0fc 100644\r?\n(?=--- a/src/audio/alstream\.cpp)", ""
# strip CRLF
$p = $p.Replace("`r`n", "`n")
[IO.File]::WriteAllText($patchPath, $p, (New-Object System.Text.UTF8Encoding($false)))
Write-Output "headers fixed"

$r = Start-Process -FilePath "git" -ArgumentList "apply --check `"$((Resolve-Path $patchPath).Path)`"" -WorkingDirectory $srcDir -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\ga_out.txt" -RedirectStandardError "$env:TEMP\ga_err.txt"
Write-Output "git apply --check rc=$($r.ExitCode)"
Get-Content "$env:TEMP\ga_err.txt" -ErrorAction SilentlyContinue | Select-Object -First 8
if ($r.ExitCode -ne 0) { exit 2 }
