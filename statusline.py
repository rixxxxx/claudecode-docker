#!/usr/bin/env python3
import json, sys
from datetime import datetime

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
        return datetime.fromtimestamp(ts).strftime("%a %H:%M")
    except (TypeError, ValueError, OSError):
        return "?"


segments = [f"[{model}] {bar} {pct}%"]
if window_size:
    segments[0] += f" ({fmt_tokens(input_tokens)}/{fmt_tokens(window_size)})"

# Anthropic only exposes rolling 5h/7d usage windows for Pro/Max subscribers --
# there is no daily or monthly quota field, so "daily" is approximated by the
# 5h window and "weekly" by the 7d window; monthly has no source to show.
rate_limits = data.get("rate_limits") or {}
quota_bits = []
five_hour = rate_limits.get("five_hour")
if five_hour:
    p = int(five_hour.get("used_percentage") or 0)
    reset = five_hour.get("resets_at")
    quota_bits.append(f"5h {p}%" + (f" ↻{fmt_reset(reset)}" if reset else ""))
seven_day = rate_limits.get("seven_day")
if seven_day:
    p = int(seven_day.get("used_percentage") or 0)
    reset = seven_day.get("resets_at")
    quota_bits.append(f"7d {p}%" + (f" ↻{fmt_reset(reset)}" if reset else ""))
if quota_bits:
    segments.append(" ".join(quota_bits))

cost = data.get("cost") or {}
total_cost = cost.get("total_cost_usd")
usage_bits = []
if input_tokens or output_tokens:
    usage_bits.append(f"{fmt_tokens(input_tokens)}in/{fmt_tokens(output_tokens)}out")
if total_cost is not None:
    usage_bits.append(f"${total_cost:.4f}")
if usage_bits:
    segments.append(" ".join(usage_bits))

print(" | ".join(segments))
