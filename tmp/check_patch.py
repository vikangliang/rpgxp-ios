import re

p = r"c:\Users\Lenovo\CodeBuddy\20260908220535\scripts\mkxp-framework\framework-entry.patch"
text = open(p, "r", encoding="utf-8").read()
lines = text.split("\n")

i = 0
total = 0
bad = 0
while i < len(lines):
    m = re.match(r"^@@ -(\d+),(\d+) \+(\d+),(\d+) @@", lines[i])
    if m:
        total += 1
        hdr = lines[i]
        oc = int(m.group(2))
        nc = int(m.group(4))
        o = 0
        n = 0
        i += 1
        while i < len(lines):
            ln = lines[i]
            if ln.startswith("@@") or ln.startswith("diff --git") or ln.startswith("---") or ln.startswith("+++"):
                break
            if ln.startswith("-"):
                o += 1
            elif ln.startswith("+"):
                n += 1
            elif ln.startswith(" ") or ln.startswith("\\"):
                o += 1
                n += 1
            elif ln == "":
                # patch 末尾/段落之间的真空行不计入任何 hunk
                pass
            i += 1
        if o != oc or n != nc:
            bad += 1
            print("BAD  %s   counted old=%d(exp %d) new=%d(exp %d)" % (hdr, o, oc, n, nc))
        continue
    i += 1

print("hunks=%d bad=%d" % (total, bad))
