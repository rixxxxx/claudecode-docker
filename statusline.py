#!/usr/bin/env python3
import json, sys
from datetime import datetime, timezone

data = json.load(sys.stdin)
model = data.get("model", {}).get("display_name", "?")

cw = data.get("context_window") or {}
pct = int(cw.get("used_percentage") or 0)
window_size = cw.get("context_window_size") or 0
input_tokens = cw.get("total_input_tokens") or 0
output_tokens = cw.get("total_output_tokens") or 0

filled = pct * 10 // 100
bar = "▓" * filled + "░" * (10 - filled)


def fmt_tokens(n):
    return f"{n / 1000:.1f}k" if n >= 1000 else str(n)


def fmt_reset(ts):
    try:
        return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%a %H:%M UTC")
    except (TypeError, ValueError, OSError):
        return "?"


segments = [f"Model: [{model}]"]
context_bit = f"Context size: {bar} {pct}%"
if window_size:
    context_bit += f" ({fmt_tokens(input_tokens)}/{fmt_tokens(window_size)})"
segments.append(context_bit)

# Anthropic only exposes rolling 5h/7d usage windows for Pro/Max subscribers --
# there is no daily or monthly quota field, so "daily" is approximated by the
# 5h window and "weekly" by the 7d window; monthly has no source to show.
rate_limits = data.get("rate_limits") or {}
five_hour = rate_limits.get("five_hour")
if five_hour:
    p = int(five_hour.get("used_percentage") or 0)
    reset = five_hour.get("resets_at")
    segments.append(f"5h-rate-limit: {p}%" + (f" ↻{fmt_reset(reset)}" if reset else ""))
seven_day = rate_limits.get("seven_day")
if seven_day:
    p = int(seven_day.get("used_percentage") or 0)
    reset = seven_day.get("resets_at")
    segments.append(f"7d-rate-limit: {p}%" + (f" ↻{fmt_reset(reset)}" if reset else ""))

if input_tokens or output_tokens:
    segments.append(f"Token usage: {fmt_tokens(input_tokens)} in / {fmt_tokens(output_tokens)} out")

cost = data.get("cost") or {}
total_cost = cost.get("total_cost_usd")
if total_cost is not None:
    segments.append(f"Costs: ${total_cost:.4f}")

print(" | ".join(segments))
