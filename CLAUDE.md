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

## Where the evidence lives

Everything this project claims comes from one of the files below. **Read them before
estimating anything.** On 2026-09-12 an assistant spent forty minutes reporting "still
going" on a prefill while `slotstream.log` held the percentage, the rate and an ETA,
and then proposed a cause that the metrics file had already refuted. Both files were
sitting there the whole time.

| File | What it is | Use it for |
| --- | --- | --- |
| `~/.slotstream/slotstream.log` | The server's own running commentary. Per-pass prefill progress (`prefill: 75520/100369 tokens (75%), ~8.6 min left`), the memory plan at startup, elastic pool moves, every refusal in full. Rotated at 10 MB. | **Anything happening right now.** `tail -f` it during any long request. It is the only place live prefill progress exists. |
| `~/.slotstream/metrics/<date>.jsonl` | 30-second samples from `monitor.sh`: pressure, free %, swap, disk, battery, and per-server `experts_per_layer`, `pool_gb`, `size_vram_gb`, `rss_mb`, `cpu_percent`, `prefix_hits/misses/evictions/held`. ~1 MB/day. | **Testing any claim about memory.** It is the richest source in the system and answers "did the pool actually shrink?" directly. |
| `~/.slotstream/metrics/exerciser.jsonl` | Every background task the exerciser ran, with timings and failures. | Trends over days; what breaks unattended. |
| `~/.slotstream/metrics/opencode.jsonl` | Karl's real OpenCode requests, including real errors. | Ground truth about actual use, as opposed to anything we synthesise. |
| `~/.slotstream/calibration-attempts.jsonl` | Append-only, every calibration attempt ever: starts with the server's refusal text, probes with tokens, timings and (since 2026-09-12) the prefill decay curve. | The durable measurement record. Survives every run. |
| `~/.slotstream/calibration.json` | The settled verdict of the **latest successful** run only. Overwritten each run; absent if no run has settled. | The current answer. Never the history. |
| `~/.slotstream/calibration.progress.json` | Live state of a running search; deleted when it finishes. | `slotkeeper calibrate --progress`. |
| `~/.slotstream/ctl.env` | Port and knobs every script and the app read. | Current configuration. |
| `~/.slotstream/ctl.env.unloadable` | The settings from the last configuration that would not start, kept deliberately. | Diagnosing a fallback. |
| `~/.slotstream/slotkeeper-bar.log` | Menu-bar app stdout. **Currently 13.8 MB of `AttributeGraph: cycle detected` — a SwiftUI dependency cycle, logged continuously, never rotated.** | Nothing useful yet. Fix the cycle and add rotation. |
| `~/.slotstream/baselines/` | Snapshots taken before a change: attempts log, ctl.env, binary sha256, patch status. | Before/after comparison, since `calibration.json` is overwritten. |

How this changes what we do:

- **Never report progress on a long request from an estimate.** The log has the real
  number. An average rate is not progress.
- **Never publish a cause without checking `metrics/<date>.jsonl` first.** It is the
  cheapest falsification available and it has already killed one confident hypothesis.
- **Never run heavy disk work while a measurement is in flight.** This model streams
  67.9 GB of experts from SSD. A `du` over the model directory, a `shasum` of a release
  binary or a recursive tree diff competes directly with prefill and will show up as a
  slowdown you then misattribute to the machine. A Swift build also flushes the page
  cache, which can leave too little reclaimable memory to restart at a large window.
- **One averaged number per request throws away the measurement.** Prefer the curve.
  `calibrate.py` now records `prefill_curve` and `prefill_decay` per probe.
- **`prefix_hits` has been 0 across every server instance.** Calibration only sends
  one-shot prompts, so prefix retention has never been exercised by our own tests. The
  "98-99% reuse" figure comes from Karl's OpenCode sessions, not from anything we run.

## Whose machine these numbers come from

**Almost every number in this repo was measured on Karl's 24 GB M4 Pro MacBook, and
most of them do not transfer.** If you have cloned this repo and pointed an assistant
at it, treat the following as *examples of what measurement produced here*, not as
facts about your machine:

- Anything in `STATUS.md` under "The answer so far", "Where the memory actually goes"
  and "The honest limits, with numbers" — including the 131,072 window carrying 100,369
  tokens, the 18.6 GB memory target, ~3 tok/s generation, and the prefill decay curve.
  All of it is this Mac, on 2026-09-12, with this model.
- Every row in `~/.slotstream/metrics/`, `calibration-attempts.jsonl` and
  `~/.slotstream/baselines/` — these are machine state, not shared results.
- The per-RAM table in `STATUS.md` is **arithmetic from the planner's ledger**, not
  measurement, on every row except the 24 GB one.

What does transfer: the patches in `patches/` (they target Slotstream 0.2.14 source),
the scripts, the ladder and search strategy in `calibrate.py`, the constraint taxonomy
in `CONSTRAINTS.md` (searched / patched / physics), and the rule that a refusal is a
symptom rather than an explanation.

**The point of `slotkeeper calibrate` is that you do not need Karl's numbers.** Run it
and it measures your machine, writes `~/.slotstream/calibration.json`, and sets the
profile to what your hardware actually carries. Anything it writes is about you;
anything checked into git is about this Mac unless it says otherwise.

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
