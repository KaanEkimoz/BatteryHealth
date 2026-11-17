#!/usr/bin/env python3
"""Lists the keys of every L("...") call in Sources/BatteryHealth, the way
String(localized:) builds them: Int interpolations become %lld, everything
else %@. Run it after adding strings and compare with the .strings files."""
import re, pathlib, sys

INT_HINTS = ("Int(", "days", "thresholdHours", "$0)", "(w)")

def key_of(literal):
    out, i = [], 0
    while i < len(literal):
        if literal.startswith("\\(", i):
            depth, j = 1, i + 2
            while depth:
                depth += {"(": 1, ")": -1}.get(literal[j], 0); j += 1
            expr = literal[i + 2:j - 1]
            is_int = (expr in ("w", "$0", "days") or any(h in expr for h in INT_HINTS)) and not any(
                s in expr for s in ("pct", "String(", "string(", "title", "Description", "shortDuration"))
            out.append("%lld" if is_int else "%@"); i = j
        elif literal[i] == "%":
            out.append("%%"); i += 1
        elif literal.startswith("\\\"", i):
            out.append('"'); i += 2
        else:
            out.append(literal[i]); i += 1
    return "".join(out)

keys = set()
for f in pathlib.Path("Sources/BatteryHealth").glob("*.swift"):
    src = f.read_text()
    for m in re.finditer(r'\bL\("((?:[^"\\]|\\.|\\\((?:[^()]|\([^()]*\))*\))*)"\)', src):
        keys.add(key_of(m.group(1)))
for k in sorted(keys):
    print(k)
