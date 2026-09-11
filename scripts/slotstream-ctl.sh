#!/usr/bin/env bash
# Lifecycle control for the local Slotstream server.
#
# Usage: slotstream-ctl.sh <command> [args]
#
#   start [profile]     Start the server in the background (default profile: everyday).
#   run [profile]       Run in the foreground. Used by the LaunchAgent.
#   stop                Graceful SIGTERM, then SIGKILL after a timeout.
#   restart [profile]   stop + start.
#   status              Process, port owner, version, plan and cache summary, profile mismatch check.
#   health              Exit 0 when /api/version answers, 1 otherwise. Quiet.
#   wait-ready [secs]   Block until healthy or timeout (default 180).
#   logs [n]            Tail the server log (default 50 lines).
#   doctor [profile]    Run `slotstream doctor --json` for a profile. Refuses while the server is loaded.
#   profile [name]      Show or persist the default profile in ~/.slotstream/profile.
#   bundle              Write a support bundle (versions, plan, logs, memory, metrics) to ~/.slotstream/bundles.
#   install-agent       Install and load the LaunchAgent (crash restart, log capture).
#   uninstall-agent     Unload and remove the LaunchAgent.
#
# Profiles (prompt+reply window): everyday=32768  conservative=16384  deep=65536, or a number.
#
# Environment overrides:
#   SLOTSTREAM_HOME (default ~/.slotstream)   SLOTSTREAM_BIN   SLOTSTREAM_PORT (11434)
#   SLOTSTREAM_MODEL (qwen3.8-flash-next:4bit)   SLOTSTREAM_MAX_PREFILL_WAIT (10 minutes)
#   SLOTSTREAM_MAX_RAM_PERCENT (unset = Slotstream default 70)   SLOTSTREAM_VISION (off)
#   SLOTSTREAM_EXTRA_ARGS (appended verbatim)   OPENCODE_CONFIG (~/.config/opencode/opencode.json)
set -euo pipefail

SLOTSTREAM_HOME="${SLOTSTREAM_HOME:-$HOME/.slotstream}"
SLOTSTREAM_BIN="${SLOTSTREAM_BIN:-$SLOTSTREAM_HOME/bin/slotstream}"
SLOTSTREAM_PORT="${SLOTSTREAM_PORT:-11434}"
SLOTSTREAM_MODEL="${SLOTSTREAM_MODEL:-qwen3.8-flash-next:4bit}"
SLOTSTREAM_MAX_PREFILL_WAIT="${SLOTSTREAM_MAX_PREFILL_WAIT:-10}"
SLOTSTREAM_VISION="${SLOTSTREAM_VISION:-off}"
OPENCODE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
LOG="$SLOTSTREAM_HOME/slotstream.log"
PROFILE_FILE="$SLOTSTREAM_HOME/profile"
PID_FILE="$SLOTSTREAM_HOME/slotstream.pid"
AGENT_LABEL="work.penz.slotstream"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
BASE="http://127.0.0.1:$SLOTSTREAM_PORT"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[slotstream-ctl %s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() { log "error: $*"; exit 1; }

resolve_profile() {
  local name="${1:-}"
  [[ -z "$name" && -f "$PROFILE_FILE" ]] && name="$(<"$PROFILE_FILE")"
  name="${name:-everyday}"
  case "$name" in
    everyday) echo 32768 ;;
    conservative) echo 16384 ;;
    deep) echo 65536 ;;
    ''|*[!0-9]*) die "unknown profile '$name' (everyday|conservative|deep|<tokens>)" ;;
    *) echo "$name" ;;
  esac
}

server_pids() { pgrep -f "slotstream serve" || true; }

port_owner() {
  # Prints "pid command" for whatever listens on the port, or nothing.
  lsof -nP -iTCP:"$SLOTSTREAM_PORT" -sTCP:LISTEN -Fpc 2>/dev/null | awk '/^p/{pid=substr($0,2)} /^c/{print pid, substr($0,2)}' | head -1
}

healthy() { curl -fsS --max-time 2 "$BASE/api/version" >/dev/null 2>&1; }

rotate_log() {
  [[ -f "$LOG" ]] || return 0
  local size
  size=$(stat -f %z "$LOG")
  (( size < 10 * 1024 * 1024 )) && return 0
  local i
  for i in 4 3 2 1; do [[ -f "$LOG.$i" ]] && mv "$LOG.$i" "$LOG.$((i + 1))"; done
  mv "$LOG" "$LOG.1"
  log "rotated $LOG (${size} bytes)"
}

check_port() {
  local owner
  owner="$(port_owner)"
  [[ -z "$owner" ]] && return 0
  local pid="${owner%% *}" cmd="${owner#* }"
  if [[ "$cmd" == slotstream ]]; then
    die "slotstream already listening on :$SLOTSTREAM_PORT (pid $pid). Use restart or stop."
  fi
  die "port :$SLOTSTREAM_PORT is held by '$cmd' (pid $pid), probably Ollama. Quit it or set SLOTSTREAM_PORT and update the OpenCode baseURL."
}

check_disk() {
  local free_gb
  free_gb=$(df -g "$SLOTSTREAM_HOME" | awk 'NR==2{print $4}')
  (( free_gb < 8 )) && log "warning: only ${free_gb} GiB free on the volume holding $SLOTSTREAM_HOME; swap growth under pressure will compete for it"
  return 0
}

serve_args() {
  local context="$1"
  local args=(serve --model "$SLOTSTREAM_MODEL" --port "$SLOTSTREAM_PORT" --max-context "$context" --max-prefill-wait "$SLOTSTREAM_MAX_PREFILL_WAIT" --vision "$SLOTSTREAM_VISION")
  [[ -n "${SLOTSTREAM_MAX_RAM_PERCENT:-}" ]] && args+=(--max-ram-percent "$SLOTSTREAM_MAX_RAM_PERCENT")
  # shellcheck disable=SC2206
  [[ -n "${SLOTSTREAM_EXTRA_ARGS:-}" ]] && args+=($SLOTSTREAM_EXTRA_ARGS)
  printf '%s\n' "${args[@]}"
}

opencode_context() {
  # Best-effort read of the slotstream provider's declared context in the OpenCode config (JSONC, so no jq).
  [[ -f "$OPENCODE_CONFIG" ]] || return 0
  awk '/"slotstream"[[:space:]]*:/{s=1} s&&/"context"[[:space:]]*:/{gsub(/[^0-9]/,"",$0); print; exit}' "$OPENCODE_CONFIG"
}

warn_profile_mismatch() {
  local server_ctx="$1" oc_ctx
  oc_ctx="$(opencode_context)"
  [[ -z "$oc_ctx" ]] && return 0
  if [[ "$oc_ctx" != "$server_ctx" ]]; then
    log "warning: OpenCode declares context $oc_ctx for provider slotstream but the server window is $server_ctx. Align them in $OPENCODE_CONFIG."
  fi
}

cmd_run() {
  local context; context="$(resolve_profile "${1:-}")"
  [[ -x "$SLOTSTREAM_BIN" ]] || die "no executable at $SLOTSTREAM_BIN"
  check_port; check_disk
  warn_profile_mismatch "$context"
  local args; mapfile -t args < <(serve_args "$context")
  log "exec $SLOTSTREAM_BIN ${args[*]}"
  exec "$SLOTSTREAM_BIN" "${args[@]}"
}

cmd_start() {
  local context; context="$(resolve_profile "${1:-}")"
  if launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1; then
    log "LaunchAgent is installed; starting through launchd"
    echo "$context" > "$PROFILE_FILE"
    launchctl kickstart "gui/$(id -u)/$AGENT_LABEL"
  else
    [[ -x "$SLOTSTREAM_BIN" ]] || die "no executable at $SLOTSTREAM_BIN"
    check_port; check_disk; rotate_log
    warn_profile_mismatch "$context"
    local args; mapfile -t args < <(serve_args "$context")
    log "starting: $SLOTSTREAM_BIN ${args[*]}"
    nohup "$SLOTSTREAM_BIN" "${args[@]}" >> "$LOG" 2>&1 &
    echo $! > "$PID_FILE"
  fi
  cmd_wait_ready "${2:-180}"
}

cmd_stop() {
  local pids; pids="$(server_pids)"
  if launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1; then
    # Stop without triggering KeepAlive restart: unload, then reload disabled state is fiddly; use kill and rely on SuccessfulExit=false.
    launchctl kill SIGTERM "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
  fi
  [[ -z "$pids" ]] && { log "not running"; rm -f "$PID_FILE"; return 0; }
  log "sending SIGTERM to $pids"
  kill -TERM $pids 2>/dev/null || true
  local i
  for i in $(seq 1 30); do
    sleep 1
    [[ -z "$(server_pids)" ]] && { log "stopped"; rm -f "$PID_FILE"; return 0; }
  done
  log "still running after 30s, sending SIGKILL"
  kill -KILL $(server_pids) 2>/dev/null || true
  rm -f "$PID_FILE"
}

cmd_wait_ready() {
  local timeout="${1:-180}" i
  for i in $(seq 1 "$timeout"); do
    healthy && { log "ready on $BASE"; return 0; }
    [[ -z "$(server_pids)" ]] && die "process exited before becoming ready; see $LOG"
    sleep 1
  done
  die "not ready after ${timeout}s"
}

cmd_status() {
  local pids; pids="$(server_pids)"
  echo "process:  ${pids:-not running}"
  echo "port:     $(port_owner || true)"
  if healthy; then
    echo "health:   ready ($(curl -fsS --max-time 2 "$BASE/api/version"))"
    local show
    show="$(curl -fsS --max-time 3 -X POST "$BASE/api/show" -H 'content-type: application/json' -d "{\"model\":\"$SLOTSTREAM_MODEL\"}" 2>/dev/null || true)"
    if [[ -n "$show" ]]; then
      echo "$show" | jq -r '
        .details.memory_plan as $p | .details.prefix_cache as $c |
        "context:  \($p.max_context_tokens) tokens (impl limit \($p.implementation_context_limit))",
        "plan:     experts \($p.experts_per_layer_cached)/layer, pool \($p.pool_gb) GB, peak \($p.expected_peak_gb|.*10|round/10) GB, target \($p.target_gb) GB of \($p.device_ram_gb|round) GB",
        "rates:    prefill ~\($p.est_prefill_tok_s) tok/s, warm decode ~\($p.est_warm_tok_s|.*10|round/10) tok/s, prefill wait \($p.max_prefill_wait_minutes) min",
        "prefix:   \(if $c then "\($c.held_tokens)/\($c.max_tokens) tok held, \($c.hits) hits, \($c.misses) misses, \($c.evictions) evictions" else "n/a" end)",
        "notes:    \(($p.notes // []) | join("; "))"'
      warn_profile_mismatch "$(echo "$show" | jq -r .details.memory_plan.max_context_tokens)"
    fi
  else
    echo "health:   not ready"
  fi
  echo "profile:  $(cat "$PROFILE_FILE" 2>/dev/null || echo "everyday (default)")"
  echo "agent:    $(launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1 && echo installed || echo "not installed")"
  echo "pressure: $(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null | sed 's/^1$/normal/;s/^2$/warning/;s/^4$/critical/')  swap: $(sysctl -n vm.swapusage | sed -E 's/.*used = ([^ ]+).*/\1/')  disk free: $(df -h "$SLOTSTREAM_HOME" | awk 'NR==2{print $4}')"
}

cmd_doctor() {
  local context; context="$(resolve_profile "${1:-}")"
  [[ -n "$(server_pids)" ]] && die "stop the server first; doctor measures the memory the loaded model is holding"
  "$SLOTSTREAM_BIN" doctor --model "$SLOTSTREAM_MODEL" --max-context "$context" --json
}

cmd_profile() {
  if [[ -n "${1:-}" ]]; then
    resolve_profile "$1" >/dev/null
    echo "$1" > "$PROFILE_FILE"
    log "default profile set to $1 ($(resolve_profile "$1") tokens); takes effect on next start"
  else
    echo "$(cat "$PROFILE_FILE" 2>/dev/null || echo everyday) -> $(resolve_profile) tokens"
  fi
}

cmd_bundle() {
  local dir="$SLOTSTREAM_HOME/bundles/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir"
  { "$SLOTSTREAM_BIN" --version; sw_vers; sysctl -n hw.model hw.memsize machdep.cpu.brand_string; } > "$dir/versions.txt" 2>&1 || true
  cmd_status > "$dir/status.txt" 2>&1 || true
  curl -fsS --max-time 3 "$BASE/api/ps" > "$dir/ps.json" 2>/dev/null || true
  curl -fsS --max-time 3 -X POST "$BASE/api/show" -H 'content-type: application/json' -d "{\"model\":\"$SLOTSTREAM_MODEL\"}" > "$dir/show.json" 2>/dev/null || true
  tail -n 300 "$LOG" > "$dir/slotstream.log.tail" 2>/dev/null || true
  { memory_pressure; sysctl vm.swapusage; } > "$dir/memory.txt" 2>&1 || true
  ls -la "$SLOTSTREAM_HOME/bin/" > "$dir/install.txt" 2>&1 || true
  shasum -a 256 "$SLOTSTREAM_HOME"/bin/slotstream "$SLOTSTREAM_HOME"/bin/mlx.metallib >> "$dir/install.txt" 2>/dev/null || true
  [[ -d "$SLOTSTREAM_HOME/metrics" ]] && tail -n 200 "$SLOTSTREAM_HOME"/metrics/*.jsonl > "$dir/metrics.tail.jsonl" 2>/dev/null || true
  grep -h '"service":"model-stats"' "$HOME/.local/share/opencode/log/"*.log 2>/dev/null | tail -n 100 > "$dir/opencode-model-stats.log" || true
  tar -czf "$dir.tar.gz" -C "$(dirname "$dir")" "$(basename "$dir")" && rm -rf "$dir"
  echo "$dir.tar.gz"
}

cmd_install_agent() {
  local template="$SCRIPT_DIR/../launchd/$AGENT_LABEL.plist"
  [[ -f "$template" ]] || die "missing $template"
  mkdir -p "$HOME/Library/LaunchAgents"
  sed -e "s|__CTL__|$SCRIPT_DIR/slotstream-ctl.sh|g" -e "s|__LOG__|$LOG|g" -e "s|__HOME__|$HOME|g" "$template" > "$AGENT_PLIST"
  if [[ -n "$(server_pids)" ]]; then
    log "a server started outside launchd is running; stop it first so launchd can own the process"
    exit 1
  fi
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
  log "installed $AGENT_PLIST"
  cmd_wait_ready 180
}

cmd_uninstall_agent() {
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
  rm -f "$AGENT_PLIST"
  log "removed LaunchAgent (server, if running, was stopped)"
}

case "${1:-}" in
  start) cmd_start "${2:-}" ;;
  run) cmd_run "${2:-}" ;;
  stop) cmd_stop ;;
  restart) cmd_stop; cmd_start "${2:-}" ;;
  status) cmd_status ;;
  health) healthy ;;
  wait-ready) cmd_wait_ready "${2:-180}" ;;
  logs) tail -n "${2:-50}" "$LOG" ;;
  doctor) cmd_doctor "${2:-}" ;;
  profile) cmd_profile "${2:-}" ;;
  bundle) cmd_bundle ;;
  install-agent) cmd_install_agent ;;
  uninstall-agent) cmd_uninstall_agent ;;
  *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
