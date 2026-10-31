$p = "c:\Users\Lenovo\CodeBuddy\20260908220535\scripts\mkxp-framework\framework-entry.patch"
$lines = Get-Content -LiteralPath $p
$total = 0
$bad = 0
$i = 0
while ($i -lt $lines.Count) {
  $ln0 = $lines[$i]
  if ($ln0 -match '^@@ -(\d+),(\d+) \+(\d+),(\d+) @@') {
    $total++
    $hdr = $ln0
    $oc = [int]$Matches[2]
    $nc = [int]$Matches[4]
    $o = 0
    $n = 0
    $i++
    # 只跳过紧跟 hunk 头的 diff 文件标记行（--- a/xxx / +++ b/xxx）
    $skipped = 0
    while ($skipped -lt 2 -and $i -lt $lines.Count) {
      if ($lines[$i] -match '^--- ' -or $lines[$i] -match '^\+\+\+ ') { $i++; $skipped++ } else { break }
    }
    while ($i -lt $lines.Count) {
      $ln = $lines[$i]
      if ($ln.StartsWith("@@") -or $ln.StartsWith("diff --git")) { break }
      if ($ln.StartsWith("-")) { $o++ }
      elseif ($ln.StartsWith("+")) { $n++ }
      else {
        # 上下文行：正常以空格开头；patch 里也存在【真空行】作为空上下文行，
        # 之前按空行跳过导致漏计（误报）。这里一律按上下文计入 old+new。
        $o++
        $n++
      }
      $i++
    }
    if (($o -ne $oc) -or ($n -ne $nc)) {
      $bad++
      "BAD  $hdr   counted old=$o(exp $oc) new=$n(exp $nc)"
    }
    continue
  }
  $i++
}
"hunks=$total bad=$bad"
