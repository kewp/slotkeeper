# Slotkeeper App Plan

Written 2026-09-11. Answers two questions: what a full app would be, and what
pushing the context window beyond 65K would take and cost.

## What exists

- `Slotkeeper/`: menu-bar supervisor with state, plan, pressure, live active
  request (prefill progress from the server log, generation rate from the
  OpenCode plugin or exerciser), exerciser status and pause, profile switching,
  logs, support bundle, and a first dashboard window (cache/pressure timeline,
  TTFT by prompt size, decode by cache size, recent runs, per-task summary).
- Data on disk under `~/.slotstream/`: monitor samples, exerciser rows, bench
  rows, live state files. Everything the app shows is read from these; the app
  never talks to the model directly beyond the read-only status endpoints.

## The full app

Keep the two-process rule from `SLOTSTREAM_DEVELOPMENT.md`: the app supervises
and visualises; Slotstream owns the model. Grow the app in this order, each
stage useful on its own.

### Stage A: Observe (1 to 2 weeks)

- Dashboard as the main window with tabs. 2026-09-12: three exist — Your work
  (your OpenCode requests, read through `scripts/report.py --requests`), Jobs
  (queue and results from `~/.slotstream/jobs`), System (cache, pressure and the
  synthetic suite). 2026-09-12 also added Server (patch status, releases, log viewer) and Health
  (services, disk, battery, sleep assertion, stuck pressure level). Still to
  come: an Experiments tab.
- Requests tab: every request from any client in one table, from the plugin's
  structured log (`~/.local/share/opencode/log`, service `model-stats`) and the
  exerciser rows. Columns: source, agent, prompt/cached/output tokens, TTFT,
  prefill and decode rate, finish, error, experts/layer, pressure. Click for the
  full record.
- Timeline: cache size, pressure, swap, battery, CPU on one axis, with request
  spans overlaid so cause and effect line up.
- Move storage from JSONL to SQLite once files exceed a few MB; keep JSONL as
  the writer format and import on launch.

### Stage B: Control (1 to 2 weeks)

- Exerciser editor: enable and weight tasks, set gap, choose repos, add a
  custom task from a prompt file, run one task now.
- Experiments: context sweep at chosen sizes with a label; profile A/B (run the
  same sweep on everyday and deep, restart between, chart both); schedule an
  evening run with the machine kept awake.
- Server tab: profile switch with OpenCode sync, start/stop/restart, releases
  and rollback, patch status, rebuild from source with checks (runs the same
  `make checks && make build` path and the release installer), log viewer.
- Health tab: LaunchAgents, disk floor, battery policy, sleep assertion, stuck
  pressure-level detector (kernel level elevated while reclaimable memory is
  high, with the reset command shown).

### Stage C: Understand (2 to 4 weeks, partly Slotstream work)

- Slotstream `/api/status`: lifecycle phase, active request id, exact prefill
  progress and ETA, queue depth, governor state and resize history, last
  failure. The app stops parsing the log once this exists.
- Structured JSON log from Slotstream, so the log viewer can filter and the
  request table is exact.
- Quality tracking: for tasks with a checkable answer (tool call shape, JSON,
  a code review that must mention a planted bug), track correctness over time
  and across profiles, not only speed.
- Cost model: fit TTFT = a + prompt/prefill_rate and decode = f(experts/layer)
  from the data, and show "this prompt would take about N minutes on the
  current plan" before OpenCode sends it.

### Stage D: Product (later, if wanted)

- Signed and notarised app bundle with the helper, metallib and release
  identity inside; model outside the bundle.
- Model download, verification and disk-space UX.
- Settings sync of the OpenCode provider, sandbox review, updates.

## Pushing context beyond 65K

Facts from the source and the planner (see `SLOTSTREAM_DEVELOPMENT.md`):

- The CLI refuses `--max-context` above 65,536. `ContextPolicy` is the gate.
- The checkpoint declares 262,144, but Slotstream qualified only 65,536.
- Above 32K the planner charges active sequence state (12 attention layers,
  2,304 bytes per token row) plus a conservative transient reserve of equal
  size, and prefix retention at 27,648 bytes per retained token.
- Prefill runs in 256 to 512-token passes at roughly 85 to 125 tok/s here.

What would happen at each step:

| Window | Extra planned memory vs 32K | Full prompt before first token | Expert cache left on this 24 GB Mac |
| ---: | ---: | ---: | --- |
| 65K | ~1.8 GB | ~9 to 13 min | fewer experts, still elastic |
| 131K | ~5.4 GB | ~18 to 26 min | near the floor (~13/layer, ~2 tok/s) |
| 262K | ~11 GB | ~35 to 50 min | does not fit alongside macOS |

"Slow is fine" covers the prefill time. It does not cover memory: state for
131K tokens costs what the entire expert cache costs today, so decode drops to
the floor for every request, not only the long ones. And every turn whose
prefix is not retained re-pays the full prefill; retention scales with the
pool, which the long window has just consumed. The window and the cache
compete for the same RAM.

Raising the ceiling is also not one constant. The development guide lists the
synchronized work: `ContextPolicy` validation and help, planner feasibility,
sequence-cache allocation and reserves, prefill workspace bounds and late
chunking, admission and output clamping, prefix-retention limits, MTP and
vision qualification, API metadata, synthetic context tests and a real
long-context acceptance run. Difficulty "High" by the author's own table.
Rough effort: one to three weeks to lift to 131K with tests, plus evening-long
qualification runs, on a machine where the result is a 2 tok/s server.

What is worth doing instead, in order:

1. **Measure the real curve.** `scripts/exerciser.py --sweep
   4000,8000,16000,24000,32000 --label everyday`, then the same on `deep` up to
   64000. The dashboard plots TTFT by prompt size. This tells us where the
   pain actually starts rather than assuming.
2. **Retain the whole window as prefix.** Costs under 1 GB for 32K, 1.8 GB for
   65K, and turns a 20-turn coding session from "re-prefill everything each
   turn" into "prefill only the new turn". Planner-level change, moderate
   difficulty, and the biggest usability win available.
3. **Compaction on the OpenCode side** so sessions stay inside the retained
   prefix. Title generation is already disabled in `opencode.json`.
4. **Run `slotstream context-check`** (weights loaded, server stopped, an
   evening slot) at 32K and 65K for exact time, tok/s and peak memory. If a
   131K experiment is still wanted after that, it is a source change plus a
   qualification run, and it belongs on a 48 GB or larger Mac.
