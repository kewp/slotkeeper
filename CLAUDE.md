# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read this first, every session

**The server is ours. Slotstream is source we compile and patch, not a service we call.**

Karl has said this repeatedly, and each time it was because an assistant treated a
Slotstream refusal as the end of the conversation:

- "we could patch slotstream. but i don't want to have to keep saying 'hey, why don't we
  just fix that'"
- "please stop saying 'oh slotstream has a limit' or 'this is slotstream's limit'. we can
  modify slotstream! we've been doing it this whole project!"
- "'the server's own reason' is not an excuse"
- "it seems like i'm constantly being told 'hey we can't do this because of some thing we
  chose to do ages ago'"

So: **quoting the server's error message is a description of a symptom, never an
explanation and never a reason to stop.** Every refusal comes from a line of Swift in
`~/.slotstream/build/*/Sources`, and that line has an author, a rationale and a number in
it. Find it. Then say which it is: a policy we can set (make it settable and search it), a
guard whose value is a guess (measure it), or arithmetic from the hardware (the only real
"no"). There are seven patches in `patches/` because six of those refusals were the first
two kinds.

Why this keeps going wrong, so the next assistant can catch it earlier: a server that
answers with a well-written error message *sounds* authoritative, and repeating it feels
like diligence. It is not. In this project the well-written message has been wrong about
what the machine can do every single time — the 65,536 window, the retention reservation,
the prefill-wait budget, the safety headroom. Treat a confident refusal as the start of the
investigation.

The check before you write a sentence containing "cannot", "limit", "refuses" or "the
server says": have you opened the Swift source and named the constant? If not, you are
guessing, and the guess has been wrong every time so far.

## The goal, which overrides everything below

**Automatically work out what this model can do on the Mac it is running on, and say
so.** No tuning by hand, no per-machine advice, no asking the user to try settings.

Rules that follow from it, and that beat any earlier decision in this repo:

- **Trace every failure to `CONSTRAINTS.md` before reporting it.** That file lists every
  limit between us and the machine's real capability, each marked searched, patched or
  physics. If a failure does not map to a row, the row is missing: add it and decide
  which it is. Reporting "it failed" without the cause, or naming a cause without saying
  whether it can be removed, is the mistake this file exists to prevent.
- **A limit in Slotstream is a work item, not an answer.** We patch Slotstream; there
  are six patches in `patches/` already. Never write or say "we can't, Slotstream caps
  it at X". Write down what the cap is, what it would take to lift it, and lift it when
  it stands between us and the goal.
- **A constant we chose earlier is not evidence.** The 55% memory cap, the 32K window,
  the ten-minute prefill budget: each was a workaround for a failure on one machine on
  one day. Calibration measures the real answer per machine and overwrites them. If a
  number is in `ctl.env` and calibration disagrees, calibration wins.
- **Measure, don't assume.** Every claim about what a machine can do must come from a
  recorded measurement on that machine, or be labelled as arithmetic from the planner's
  ledger.
- **Degrade, never refuse.** When something does not fit, the server gives up the
  cheapest thing (retention, then pool, then chunk size) and keeps serving. Refusing a
  request is the last resort, and it is a bug report against this rule.
- **The user should never have to run the experiment.** If an answer needs a
  measurement, the software takes the measurement itself, when the machine is free.

## What this is

The home of a larger effort: work out automatically what a local model (Slotstream serving Qwen3.8-Flash-Next) can do on whatever Mac it is running on, and run it there continuously while the Mac stays usable. The 24 GB M4 Pro this was written on is one data point, not the target. It holds:

- `model-stats.ts`: single-file OpenCode plugin with live prefill timing, completion stats, and failure diagnostics.
- `patches/`: five Slotstream source patches, applied in alphabetical order: retry wording + server-side failure logging, then prefix retention (`--prefix-cache-tokens n|full` on `RuntimeAllocationPolicy`, charged against the pool), then the governor pressure ceiling (no regrowth past the pool that met pressure for 20 min), then resume-after-refusal (a boundary-safe failure keeps its committed prefix; a shrink no longer drops a large one), then the stale-pressure cross-check (`RequestPressurePolicy`). `scripts/slotkeeper patch --status` shows which are in the installed binary. After changing a public struct's stored fields, clean `.build/arm64-apple-macosx/debug` before `make checks`: an incremental build once left the test module on the old layout and a check failed with a nonsense value. Regenerate an incremental patch with `diff -ruN -x .build -x lib -x '*.orig' <before> <after>` and rewrite the path prefixes to `a/` and `b/`.
- `scripts/` + `launchd/`: lifecycle control, LaunchAgents (server, monitor, exerciser), metrics monitor, continuous exerciser, report, benchmark, pressure drill, release installer, plugin installer. Bash + jq + python3, no build step.
- `Slotkeeper/`: SwiftUI menu-bar supervisor prototype (`swift build` / `swift run` in that directory; macOS 14+, tools 5.10, `-parse-as-library`). It shells out to `scripts/slotkeeper` and never loads the model.
- `LOCAL_LLM_ROADMAP.md` (start with "Where things stand"), `SLOTSTREAM_DEVELOPMENT.md`, `SLOTSTREAM_RECOVERY.md`, `APP_PLAN.md`, `APP_IMPLEMENTATION.md`, `patches/README.md`: the operational reference. For any app or exerciser work, read `APP_IMPLEMENTATION.md` first: it has the data contracts, the code map, staged tasks with verification steps, and the known traps. Keep them accurate when behavior changes; the roadmap's "Plan Review" and "Tooling Added" sections track what exists versus what is planned.

## Commands

```sh
npm install
npm run typecheck          # tsc --noEmit; the only automated check. No test suite, no linter.
git diff --check           # whitespace check used before commits
patch --dry-run --forward --batch -p1 < patches/slotstream-0.2.14-opencode-retry.patch   # verify patch applies to stock Slotstream 0.2.14 source
```

Validation is manual: install the plugin, restart OpenCode, run a request against Slotstream, and check the toast and `~/.local/share/opencode/log/opencode.log` (service `model-stats`).

New machine: `scripts/setup.sh` (see README). Script checks: `bash -n scripts/*.sh`, `python3 -m py_compile scripts/bench.py`, `plutil -lint launchd/*.plist`. `scripts/slotkeeper status` and `MONITOR_ONCE=1 scripts/monitor.sh` are read-only against the live server and safe to run any time.

## Operating rules

- Never restart or stop the Slotstream server while a request is in flight, and do not restart it just to test something; the user relies on it from OpenCode. Read-only endpoints (`/api/version`, `/api/ps`, `/api/show`) are fine. `slotstream doctor` must not run while the model is loaded.
- `scripts/pressure-drill.sh` and `scripts/bench.py --set long` load the machine; run them only when asked.
- Server window and OpenCode's `limit.context` for provider `slotstream` must match. `slotkeeper status` warns on mismatch. The OpenCode config is JSONC (trailing commas), so do not parse it with `jq`.
- Profiles: everyday 32768, conservative 16384, deep 65536, persisted in `~/.slotstream/profile`. Port and other knobs live in `~/.slotstream/ctl.env` (currently port 11435; Ollama keeps 11434). All scripts and the app read that file.
- Four LaunchAgents: `local.slotkeeper` (server), `-monitor`, `-exerciser`, and `local.slotkeeper-bar` (menu-bar app). `stop` unloads the server job so KeepAlive cannot respawn it; `start` bootstraps it again. Manage them only through `scripts/slotkeeper`; `launchctl kickstart` hangs in this environment, the script uses bootout/bootstrap. Side-agent scripts must be executable (launchd exits 78 otherwise).
- "How is it going?" means: run `scripts/report.py` (add `--hours N`), `scripts/slotkeeper exerciser status`, and look at recent failures in `~/.slotstream/metrics/exerciser.jsonl`.
- The server runs under launchd (`local.slotkeeper`). Use the control script to stop/start; do not `pkill` it, launchd will respawn it after 30 s and `pkill -f "slotstream serve"` also kills any foreground test run.
- Scripts must stay compatible with `/bin/bash` 3.2 (launchd runs them with it): no `mapfile`, no associative arrays. `lsof` exits 1 on no match, so guard pipelines under `pipefail`.
- Rebuilding Slotstream: `scripts/slotkeeper patch` (extract shipped source, apply `patches/*.patch`, `make checks && make build`, install as a new release, restart; `--build-only` to skip the install; `--status` to see which patches the installed binary has). About 5 minutes. Manual steps are in `patches/README.md`.

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
