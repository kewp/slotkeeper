#!/usr/bin/env bash
# Samples memory pressure, swap, disk, Slotstream process and plan/cache state to a JSONL file.
# One line per sample, one file per day: ~/.slotstream/metrics/YYYY-MM-DD.jsonl
#
# Usage: monitor.sh [interval-seconds]   (default 30)
#   MONITOR_ONCE=1 monitor.sh            print one sample to stdout and exit
#
# Posts a macOS notification when free disk drops below MONITOR_DISK_FLOOR_GB (default 6)
# or when pressure is critical for MONITOR_CRITICAL_ALERT consecutive samples (default 4).
set -uo pipefail

INTERVAL="${1:-30}"
SLOTSTREAM_HOME="${SLOTSTREAM_HOME:-$HOME/.slotstream}"
if [[ -f "$SLOTSTREAM_HOME/ctl.env" ]]; then while IFS='=' read -r k v; do [[ "$k" =~ ^[A-Z_]+$ ]] && [[ -z "${!k:-}" ]] && export "$k=$v"; done < "$SLOTSTREAM_HOME/ctl.env"; fi
SLOTSTREAM_PORT="${SLOTSTREAM_PORT:-11434}"
SLOTSTREAM_MODEL="${SLOTSTREAM_MODEL:-qwen3.8-flash-next:4bit}"
BASE="http://127.0.0.1:$SLOTSTREAM_PORT"
OUT_DIR="$SLOTSTREAM_HOME/metrics"
DISK_FLOOR="${MONITOR_DISK_FLOOR_GB:-6}"
CRITICAL_ALERT="${MONITOR_CRITICAL_ALERT:-4}"
mkdir -p "$OUT_DIR"

notify() { osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true; }

sample() {
  local ts level free swap_used pid rss cpu disk_free_gb ps show battery thermal
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  level="$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 0)"
  free="$(memory_pressure 2>/dev/null | awk -F': *' '/free percentage/{gsub(/%/,"",$2); print $2}')"
  swap_used="$(sysctl -n vm.swapusage | sed -E 's/.*used = ([0-9.,]+)M.*/\1/; s/,/./')"
  disk_free_gb="$(df -g "$SLOTSTREAM_HOME" | awk 'NR==2{print $4}')"
  pid="$(pgrep -f 'slotstream serve' | head -1 || true)"
  if [[ -n "$pid" ]]; then
    read -r rss cpu < <(ps -o rss=,%cpu= -p "$pid" | awk '{print $1, $2}')
    cpu="${cpu/,/.}"
  else
    rss=0; cpu=0
  fi
  battery="$(pmset -g batt 2>/dev/null | awk '/InternalBattery/{match($0,/[0-9]+%/); pct=substr($0,RSTART,RLENGTH-1); state=($0 ~ /discharging/)?"battery":"ac"; print pct " " state}')"
  thermal="$(pmset -g therm 2>/dev/null | awk -F': ' '/CPU_Speed_Limit/{print $2}')"
  ps="$(curl -fsS --max-time 2 "$BASE/api/ps" 2>/dev/null || echo '{}')"
  show="$(curl -fsS --max-time 3 -X POST "$BASE/api/show" -H 'content-type: application/json' -d "{\"model\":\"$SLOTSTREAM_MODEL\"}" 2>/dev/null || echo '{}')"

  jq -cn \
    --arg ts "$ts" --argjson level "${level:-0}" --argjson free "${free:-null}" --argjson swap "${swap_used:-null}" \
    --argjson disk "${disk_free_gb:-null}" --arg pid "${pid:-}" --argjson rss_kb "${rss:-0}" --argjson cpu "${cpu:-0}" \
    --arg battery "${battery:-}" --arg thermal "${thermal:-}" --argjson ps "$ps" --argjson show "$show" '
    ($show.details.memory_plan // $ps.models[0].details.memory_plan // {}) as $plan |
    ($show.details.prefix_cache // {}) as $cache |
    {
      ts: $ts,
      pressure: ({"1":"normal","2":"warning","4":"critical"}[$level|tostring] // "unknown"),
      free_percent: $free, swap_used_mb: $swap, disk_free_gb: $disk,
      battery: (if $battery == "" then null else $battery end),
      cpu_speed_limit: (if $thermal == "" then null else ($thermal|tonumber? // $thermal) end),
      slotstream: {
        pid: (if $pid == "" then null else ($pid|tonumber) end),
        rss_mb: (($rss_kb / 1024)|floor), cpu_percent: $cpu,
        ready: ($ps != {}),
        loaded: (($ps.models // []) | length > 0),
        size_vram_gb: (($ps.models[0].size_vram // 0) / 1e9 | .*100 | round / 100),
        experts_per_layer: $plan.experts_per_layer_cached, pool_gb: $plan.pool_gb,
        max_context: $plan.max_context_tokens, est_warm_tok_s: $plan.est_warm_tok_s, est_prefill_tok_s: $plan.est_prefill_tok_s,
        prefix_held_tokens: $cache.held_tokens, prefix_hits: $cache.hits, prefix_misses: $cache.misses, prefix_evictions: $cache.evictions,
        notes: ($plan.notes // [])
      }
    }'
}

if [[ "${MONITOR_ONCE:-}" == 1 ]]; then sample; exit 0; fi

critical_streak=0
disk_alerted=0
echo "monitor: writing to $OUT_DIR every ${INTERVAL}s (pid $$)" >&2
while true; do
  line="$(sample)" || line=""
  if [[ -n "$line" ]]; then
    echo "$line" >> "$OUT_DIR/$(date +%Y-%m-%d).jsonl"
    if [[ "$(jq -r .pressure <<<"$line")" == critical ]]; then
      critical_streak=$((critical_streak + 1))
      (( critical_streak == CRITICAL_ALERT )) && notify "Slotstream monitor" "Memory pressure critical for $((CRITICAL_ALERT * INTERVAL))s"
    else
      critical_streak=0
    fi
    disk="$(jq -r '.disk_free_gb // 999' <<<"$line")"
    if (( disk < DISK_FLOOR )) && (( disk_alerted == 0 )); then
      notify "Slotstream monitor" "Only ${disk} GiB free on disk"; disk_alerted=1
    elif (( disk >= DISK_FLOOR )); then
      disk_alerted=0
    fi
  fi
  sleep "$INTERVAL"
done
