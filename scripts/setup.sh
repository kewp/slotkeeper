#!/usr/bin/env bash
# One-shot setup for a new machine.
#
#   scripts/setup.sh                 interactive: checks, settings, plugin install, optional services
#   scripts/setup.sh --yes           accept defaults (port 11435, everyday profile, install all services)
#   scripts/setup.sh --port 11435 --profile everyday --no-services --link
#
# --link installs the OpenCode plugin as a re-export of this checkout (edits take effect on the
# next OpenCode restart) instead of a standalone copy.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTL="$REPO/scripts/slotkeeper"
SLOTSTREAM_HOME="${SLOTSTREAM_HOME:-$HOME/.slotstream}"
YES=0; PORT=""; PROFILE=""; SERVICES=""; LINK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1 ;;
    --port) PORT="$2"; shift ;;
    --profile) PROFILE="$2"; shift ;;
    --services) SERVICES=1 ;;
    --no-services) SERVICES=0 ;;
    --link) LINK=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac; shift
done

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; }
ask() { # ask "prompt" "default" -> echoes answer
  if [[ $YES == 1 ]]; then echo "$2"; return; fi
  read -r -p "$1 [$2]: " a; echo "${a:-$2}"
}

echo "Checking requirements"
missing=0
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] && ok "macOS on Apple Silicon" || { fail "needs macOS on Apple Silicon"; missing=1; }
for tool in python3 jq node npm curl lsof; do
  command -v "$tool" >/dev/null && ok "$tool $(command -v "$tool")" || { fail "$tool not found"; missing=1; }
done
if command -v python3 >/dev/null; then
  v=$(python3 -c 'import sys;print(sys.version_info[:2] >= (3,9))'); [[ $v == True ]] || { fail "python3 3.9+ required"; missing=1; }
fi
command -v swift >/dev/null && ok "swift $(swift --version 2>&1 | head -1 | sed 's/.*version //;s/ .*//') (menu-bar app)" || warn "swift not found: scripts work, the menu-bar app will not build (install Xcode or Command Line Tools)"
bin="$SLOTSTREAM_HOME/bin/slotstream"
if [[ -x "$bin" ]]; then ok "slotstream $("$bin" --version 2>/dev/null) at $bin"
elif command -v slotstream >/dev/null; then warn "slotstream found in PATH but not at $bin; set SLOTSTREAM_BIN in $SLOTSTREAM_HOME/ctl.env"
else fail "slotstream not found at $bin. Install Slotstream and pull the model first (see its own docs)."; missing=1; fi
[[ -d "$SLOTSTREAM_HOME/models" ]] && ok "models directory present" || warn "no $SLOTSTREAM_HOME/models yet: run 'slotstream pull' before starting the server"
[[ -f "$HOME/.config/opencode/opencode.json" ]] && ok "OpenCode config found" || warn "no ~/.config/opencode/opencode.json; the plugin needs OpenCode installed"
(( missing == 0 )) || { echo; echo "Fix the items marked ✗ and run again."; exit 1; }

echo
echo "Settings"
PORT="${PORT:-$(ask "Server port (11434 collides with Ollama if you run it)" 11435)}"
PROFILE="${PROFILE:-$(ask "Default profile: everyday (32K), conservative (16K), deep (65K)" everyday)}"
# Slotstream sizes the expert cache from this machine on every start, so nothing here
# needs a memory knob. Only add SLOTSTREAM_MAX_RAM_PERCENT if a sweep shows long prompts
# failing under memory pressure; copying another machine's value only holds this one back.
mkdir -p "$SLOTSTREAM_HOME/metrics"
{
  echo "SLOTSTREAM_PORT=$PORT"
  echo "SLOTSTREAM_CTL=$CTL"
  echo "EXERCISER_REPOS=$REPO"
} > "$SLOTSTREAM_HOME/ctl.env"
echo "$PROFILE" > "$SLOTSTREAM_HOME/profile"
ok "wrote $SLOTSTREAM_HOME/ctl.env and profile ($PROFILE)"

echo
echo "OpenCode plugin"
(cd "$REPO" && npm install --silent && npm run --silent typecheck) && ok "dependencies installed, plugin typechecks"
if [[ $LINK == 1 ]]; then "$REPO/scripts/install-plugin.sh" --link | tail -1; else "$REPO/scripts/install-plugin.sh" | sed -n '1p'; fi
cat <<EOF

  Add (or check) this provider in ~/.config/opencode/opencode.json, then restart OpenCode:

  "slotstream": {
    "npm": "@ai-sdk/openai-compatible",
    "name": "slotstream (local)",
    "options": { "baseURL": "http://localhost:$PORT/v1" },
    "models": {
      "qwen3.8-flash-next:4bit": {
        "name": "qwen3.8-flash-next:4bit",
        "limit": { "context": $("$CTL" profile 2>/dev/null | sed 's/.*-> //;s/ tokens//'), "output": 4096 }
      }
    }
  }

  The control script keeps "context" and the port in sync with the profile on every start.
EOF

echo
if [[ -z "$SERVICES" ]]; then
  a=$(ask "Install background services now? (server at login + crash restart, metrics monitor, exerciser, menu-bar app) y/n" y)
  [[ $a == y* ]] && SERVICES=1 || SERVICES=0
fi
if [[ $SERVICES == 1 ]]; then
  echo "Installing services"
  if pgrep -f "slotstream serve" >/dev/null; then
    warn "a slotstream server is already running outside launchd; stop it first ('$CTL stop') and rerun, or skip services"
  else
    "$CTL" install-agent 2>&1 | tail -1
  fi
  "$CTL" monitor start 2>&1 | tail -1
  "$CTL" exerciser start 2>&1 | tail -1
  if command -v swift >/dev/null; then "$CTL" bar install 2>&1 | tail -1; fi
  echo
  "$CTL" status
else
  echo "Skipped services. Later: $CTL install-agent | monitor start | exerciser start | bar install"
fi

cat <<EOF

Done. Everyday commands:
  $CTL status                  server, plan, cache, pressure
  $CTL restart deep            switch to the 65K profile (and back with 'restart everyday')
  $CTL exerciser status        background test suite; pause/resume from the menu bar
  $REPO/scripts/report.py      what has been measured
See README.md for the rest.
EOF
