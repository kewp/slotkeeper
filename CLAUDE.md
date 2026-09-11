# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

The home of a larger effort: run a local model (Slotstream serving Qwen3.8-Flash-Next on a 24 GB M4 Pro) continuously while the Mac stays usable. It holds:

- `model-stats.ts`: single-file OpenCode plugin with live prefill timing, completion stats, and failure diagnostics.
- `patches/`: Slotstream source patch making pre-output memory-pressure errors retryable by OpenCode.
- `scripts/` + `launchd/`: lifecycle control, LaunchAgent, metrics monitor, benchmark, pressure drill, plugin installer. Bash + jq + python3, no build step.
- `SlotstreamBar/`: SwiftUI menu-bar supervisor prototype (`swift build` / `swift run` in that directory; macOS 14+, tools 5.10, `-parse-as-library`). It shells out to `scripts/slotstream-ctl.sh` and never loads the model.
- `LOCAL_LLM_ROADMAP.md`, `SLOTSTREAM_DEVELOPMENT.md`, `SLOTSTREAM_RECOVERY.md`: the operational reference. Keep them accurate when behavior changes; the roadmap's "Plan Review" and "Tooling Added" sections track what exists versus what is planned.

## Commands

```sh
npm install
npm run typecheck          # tsc --noEmit; the only automated check. No test suite, no linter.
git diff --check           # whitespace check used before commits
patch --dry-run --forward --batch -p1 < patches/slotstream-0.2.14-opencode-retry.patch   # verify patch applies to stock Slotstream 0.2.14 source
```

Validation is manual: install the plugin, restart OpenCode, run a request against Slotstream, and check the toast and `~/.local/share/opencode/log/opencode.log` (service `model-stats`).

Script checks: `bash -n scripts/*.sh`, `python3 -m py_compile scripts/bench.py`, `plutil -lint launchd/*.plist`. `scripts/slotstream-ctl.sh status` and `MONITOR_ONCE=1 scripts/monitor.sh` are read-only against the live server and safe to run any time.

## Operating rules

- Never restart or stop the Slotstream server while a request is in flight, and do not restart it just to test something; the user relies on it from OpenCode. Read-only endpoints (`/api/version`, `/api/ps`, `/api/show`) are fine. `slotstream doctor` must not run while the model is loaded.
- `scripts/pressure-drill.sh` and `scripts/bench.py --set long` load the machine; run them only when asked.
- Server window and OpenCode's `limit.context` for provider `slotstream` must match. `slotstream-ctl.sh status` warns on mismatch. The OpenCode config is JSONC (trailing commas), so do not parse it with `jq`.
- Profiles: everyday 32768, conservative 16384, deep 65536, persisted in `~/.slotstream/profile`. Port and other knobs live in `~/.slotstream/ctl.env` (currently port 11435; Ollama keeps 11434). All scripts and the app read that file.
- The server runs under launchd (`work.penz.slotstream`). Use the control script to stop/start; do not `pkill` it, launchd will respawn it after 30 s and `pkill -f "slotstream serve"` also kills any foreground test run.
- Scripts must stay compatible with `/bin/bash` 3.2 (launchd runs them with it): no `mapfile`, no associative arrays. `lsof` exits 1 on no match, so guard pipelines under `pipefail`.
- Rebuilding Slotstream: extract `~/.slotstream/bin/build-source.tar.gz.0.2.14.original` (kept in the first release dir), apply the repo patch, copy `~/.slotstream/bin/mlx.metallib` to `Tools/lib/mlx-0.31.1.metallib`, then `make checks && make build` (about 5 minutes). Install with `scripts/install-release.sh`.

## Deployment

OpenCode loads `~/.config/opencode/plugins/model-stats.ts`. On this machine that file is a re-export shim pointing at this repo by absolute path, so edits here take effect on the next OpenCode restart. A running OpenCode keeps the old code until restarted. The README documents a plain copy as the alternative install.

`@opencode-ai/plugin` / `@opencode-ai/sdk` imports are type-only. Keep it that way unless the SDK version in `~/.config/opencode/package.json` is aligned with this repo's.

## Architecture of `model-stats.ts`

Everything hangs off two OpenCode hooks returned from `ModelStats`:

- `chat.params` fires when a request starts. It filters on `PROVIDER_ID` (skipping the `title` agent), derives the Ollama-style runtime URL (`/api/ps`, `/api/show`) from the provider base URL, and calls `startPrefill`, which sets a `setInterval` toast refreshed every `PREFILL_REFRESH_MS`. In parallel it estimates prompt size by walking `client.session.messages` back to the last completed assistant message for the same provider+agent and adding ~4 chars/token for everything after it.
- `event` handles four event types:
  - `session.status` with `retry` renders OpenCode's retry attempt/countdown.
  - `message.part.updated` records first output (text, reasoning, or non-pending tool) per message and stops the prefill timer. This is how TTFT is measured.
  - `session.idle` stops any timers for the session.
  - `message.updated` for a completed or errored assistant message builds the final report (success: token/context/rate lines; failure: error code, Slotstream plan/cache state, macOS memory snapshot via `memory_pressure` and `sysctl`), shows a 24-hour toast, and writes a structured record with `client.app.log`.

State is keyed by `sessionID:agent` (`inFlight`, `previousPromptBySession`) or by `messageID` (`timing`, `reported`). `reported` is a dedupe set cleared past 500 entries. Runtime stats from Slotstream are cached per model in `runtimeByModel` and refreshed on each timer tick and at report time.

Constraints that shape the code:

- OpenAI-compatible streaming gives no prefill progress, so live prompt counts and ETAs are estimates and must stay labeled as such.
- The plugin never re-submits requests. Retry ownership belongs to OpenCode's loop; the Slotstream patch only adjusts error wording (`try your request again`) so OpenCode's classifier enters that loop, and only when pressure hits before the first token.
- OpenCode's TUI has one toast slot, so the structured log is the durable record.

## Slotstream patch

`patches/slotstream-0.2.14-opencode-retry.patch` applies to stock 0.2.14 source only. The installed `~/.slotstream/bin/build-source.tar.gz` is already patched; never apply the patch to it, and never accept `patch` offers to reverse. Rebuild, install, and rollback steps with current artifact hashes are in `SLOTSTREAM_RECOVERY.md`; the patch workflow and Slotstream check tiers (T0–T4) are in `SLOTSTREAM_DEVELOPMENT.md`. When Slotstream is upgraded, recreate the smallest equivalent change rather than forcing the old patch.
