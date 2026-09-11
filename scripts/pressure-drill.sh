#!/usr/bin/env bash
# Verify the memory-pressure recovery contract end to end without waiting for real pressure.
#
# macOS `memory_pressure -S -l <level>` makes the kernel *report* a pressure level without
# allocating memory. Slotstream subscribes to those notifications, so a simulated critical
# level during prefill should make it fail the request with the retryable wording
# ("try your request again") that OpenCode's retry classifier recognizes.
#
# Usage: pressure-drill.sh [seconds-into-request] [level]     (default: 8 seconds, critical)
#
# What it does:
#   1. starts a medium bench request (~1.5K prompt tokens, so prefill lasts long enough to hit)
#   2. after N seconds, simulates the pressure level for 10 seconds (may prompt for sudo)
#   3. reports whether the request failed before first token with retryable wording,
#      and shows Slotstream's stderr line for the failure
#
# Run it only when nothing else is using the server. Other applications also see the simulated
# pressure and may purge caches for those 10 seconds. It does not touch the running binary.
set -uo pipefail

DELAY="${1:-8}"
LEVEL="${2:-critical}"
SLOTSTREAM_HOME="${SLOTSTREAM_HOME:-$HOME/.slotstream}"
LOG="$SLOTSTREAM_HOME/slotstream.log"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$(mktemp -t pressure-drill)"

[[ "$LEVEL" == warn || "$LEVEL" == critical ]] || { echo "level must be warn or critical" >&2; exit 2; }
"$DIR/slotkeeper" health || { echo "server not ready" >&2; exit 1; }

log_start=$(wc -l < "$LOG")
echo "drill: starting medium request; simulating $LEVEL pressure after ${DELAY}s"
python3 "$DIR/bench.py" --set medium --label "pressure-drill-$LEVEL" > "$OUT" 2>&1 &
bench_pid=$!
sleep "$DELAY"

# -s makes the simulator reset the level itself when the duration ends. Never kill it early:
# a killed simulator leaves kern.memorystatus_vm_pressure_level stuck at the simulated value
# (recover with: sudo memory_pressure -S -l warn -s 1).
if [[ $(id -u) -eq 0 ]]; then sim=(memory_pressure -S -l "$LEVEL" -s 10); else sim=(sudo memory_pressure -S -l "$LEVEL" -s 10); fi
echo "drill: ${sim[*]}"
"${sim[@]}" >/dev/null 2>&1
wait "$bench_pid" 2>/dev/null
echo "drill: kernel pressure level now $(sysctl -n kern.memorystatus_vm_pressure_level) (1 = normal)"

echo
echo "== bench result"
cat "$OUT"
echo
echo "== slotstream log since drill start"
tail -n +"$((log_start + 1))" "$LOG"
echo
row=$(tail -n 1 "$SLOTSTREAM_HOME/metrics/bench.jsonl")
if jq -e '.error != null' <<<"$row" >/dev/null; then
  if jq -e '.error | tostring | test("try your request again")' <<<"$row" >/dev/null; then
    echo "RESULT: request failed with RETRYABLE wording (OpenCode would retry). Contract holds."
  elif jq -e '.ttft_s == null' <<<"$row" >/dev/null; then
    echo "RESULT: request failed before first token but WITHOUT retryable wording. The installed binary may predate the patch, or this pressure path is not covered."
  else
    echo "RESULT: request failed AFTER first token (non-retryable by design)."
  fi
else
  echo "RESULT: request completed. Pressure did not interrupt it (simulation too late, too short, or level ignored). Try a smaller delay or --set long."
fi
rm -f "$OUT"
