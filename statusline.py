#!/usr/bin/env python3
import json, sys

data = json.load(sys.stdin)
model = data.get("model", {}).get("display_name", "?")
cw = data.get("context_window") or {}
pct = int(cw.get("used_percentage") or 0)

filled = pct * 10 // 100
bar = "▓" * filled + "░" * (10 - filled)
print(f"[{model}] {bar} {pct}%")
