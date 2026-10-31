cd c:\Users\Lenovo\CodeBuddy\20260908220535
Write-Host "=== git status ==="
git status --short
Write-Host "=== shader-precision.patch vs HEAD ==="
git diff --stat HEAD -- scripts/mkxp-framework/shader-precision.patch
Write-Host "=== patch content ==="
Get-Content scripts/mkxp-framework/shader-precision.patch
$raw = [IO.File]::ReadAllBytes('scripts/mkxp-framework\shader-precision.patch')
$t = [Text.Encoding]::UTF8.GetString($raw)
$crlf = ([regex]::Matches($t, "`r`n")).Count
$lf = ([regex]::Matches($t, "(?<!`r)`n")).Count
Write-Host ("=== endings: bytes={0} CRLF={1} bareLF={2} BOM={3}" -f $raw.Length, $crlf, $lf, ($raw[0] -eq 0xEF))
"=== bash -n ==="
bash -n scripts/build_mkxp_ios.sh 2>&1; "bash -n rc=$LASTEXITCODE"
