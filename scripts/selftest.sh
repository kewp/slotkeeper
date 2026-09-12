#!/usr/bin/env bash
# Check that this checkout is sound, without loading the model or touching the server.
#
#   scripts/selftest.sh          syntax, plists, CLI surfaces, read-only data paths
#   scripts/selftest.sh --live   also probe the running server's read-only endpoints
#
# Everything here is safe to run at any time, including while a request is in flight.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE=0
[[ "${1:-}" == "--live" ]] && LIVE=1
pass=0 fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$((fail + 1)); }
check() { # name, command...
  local name="$1"; shift
  local out; out="$("$@" 2>&1)"
  if [[ $? -eq 0 ]]; then ok "$name"; else no "$name" "$(tail -2 <<<"$out")"; fi
}

echo "shell scripts"
for f in "$REPO"/scripts/*.sh "$REPO/scripts/slotkeeper"; do
  check "$(basename "$f") parses" bash -n "$f"
done

echo "python scripts"
for f in "$REPO"/scripts/*.py; do
  check "$(basename "$f") compiles" python3 -m py_compile "$f"
done

echo "launchd plists"
for f in "$REPO"/launchd/*.plist; do
  [[ -e "$f" ]] || continue
  check "$(basename "$f") is valid" plutil -lint "$f"
done

echo "plugin"
if command -v npm >/dev/null && [[ -d "$REPO/node_modules" ]]; then
  check "model-stats.ts typechecks" npm --prefix "$REPO" run --silent typecheck
else
  echo "  skip  model-stats.ts typecheck (run npm install first)"
fi

echo "command surfaces"
check "slotkeeper usage" bash "$REPO/scripts/slotkeeper" --help
check "jobs list" python3 "$REPO/scripts/jobs.py" list
check "jobs report" python3 "$REPO/scripts/jobs.py" report --hours 1
check "report summary" python3 "$REPO/scripts/report.py" --hours 1
check "report --requests is json" bash -c "python3 '$REPO/scripts/report.py' --requests --json --hours 1 | python3 -c 'import json,sys; json.load(sys.stdin)'"

echo "data paths"
home="${SLOTSTREAM_HOME:-$HOME/.slotstream}"
[[ -d "$home" ]] && ok "$home exists" || no "$home is missing" "run scripts/setup.sh"
[[ -f "$home/ctl.env" ]] && ok "ctl.env present" || echo "  skip  ctl.env (defaults apply)"
db="${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"
if [[ -f "$db" ]]; then
  check "OpenCode database is readable" sqlite3 -readonly "$db" "select count(*) from message limit 1;"
else
  echo "  skip  OpenCode database (not found at $db)"
fi

if (( LIVE )); then
  echo "live server (read-only)"
  port="$(grep -E '^SLOTSTREAM_PORT=' "$home/ctl.env" 2>/dev/null | cut -d= -f2)"
  port="${port:-11434}"
  check "/api/version answers" curl -fsS -m 5 "http://127.0.0.1:$port/api/version"
  check "/api/show answers" curl -fsS -m 10 "http://127.0.0.1:$port/api/show" -d '{"name":"'"${SLOTSTREAM_MODEL:-qwen3.8-flash-next:4bit}"'"}'
  check "patch status readable" bash "$REPO/scripts/slotkeeper" patch --status
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $(( fail > 0 ))
