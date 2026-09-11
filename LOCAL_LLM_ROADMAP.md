# Reliable Local LLM Roadmap

Last updated: 2026-09-11 (plan review and tooling added)

## Where things stand (2026-09-11, end of day)

Read this first after a context reset. Everything below it is history and
reasoning; this is the state.

- Project renamed to Slotkeeper, repo at `~/slotkeeper`, remote
  `github.com/kewp/slotkeeper` (GitHub rename and push pending at time of
  writing). Public-ready: `scripts/setup.sh`, newcomer README, no personal
  paths, neutral LaunchAgent labels `local.slotkeeper*`.
- Server: Slotstream 0.2.14 with both patches, 32K everyday profile, port
  11435, launchd, `caffeinate -s` on AC. Both patches verified live.
- Running services: server, monitor (30 s), exerciser (12 tasks, 90 s gap),
  menu-bar app with dashboard window. All survive reboot.
- Data: `~/.slotstream/metrics/`. Ask "how is it going" → `scripts/report.py`.
- Done today: 32K switch, port move, patched builds ×3, retry contract and
  stale-pressure fix verified, exerciser and sweep mode, dashboard, live
  active-request stats, `slotkeeper patch` one-command rebuild, hand-off docs.
- 19:22: full-window prefix retention (C2) built, checked and installed
  (third patch `patches/slotstream-0.2.14-prefix-retention.patch`,
  `SLOTSTREAM_PREFIX_CACHE_TOKENS=full` in ctl.env, release
  `slotstream-0.2.14-local-20260911192148`). Plan after restart: 43/layer,
  5.7 GB pool, 32768 tokens retained (was 11940). Exerciser restarted with
  the new `multi-turn-long` task. The debug build at 19:12 interrupted a
  17.7K-token prefill on the live server with a pressure failure; the
  everyday sweep Karl started earlier may be missing that point.
- Next, in order: (1) read `multi-turn-long` rows as they arrive
  (`scripts/report.py`): turn-2 TTFT must be at most half of turn-1, and
  `slotkeeper status` should show hits climbing; (2) read the sweep, rerun
  any missing sizes, then run it on deep; (3) app Stage A
  (`APP_IMPLEMENTATION.md`); (4) upstream the three patches
  (`patches/README.md` has the PR text).
- Karl's preferences: slow is fine, evening/overnight runs are expected, the
  Mac must stay usable, a cheaper model may continue the work (hence the
  hand-off docs).

## Goal

Run a useful local model continuously while the Mac remains responsive for
normal work. The service should adapt to changing memory availability, recover
safely, explain failures, and require little terminal supervision.

Reliability matters more than maximizing context, expert residency, or benchmark
throughput. A slightly slower model that remains available is preferable to one
that repeatedly enters memory pressure or disrupts other applications.

## Current State

Updated 2026-09-11 17:00 CEST after the switch to the everyday profile.

- Slotstream 0.2.14 with the full repo patch serves `qwen3.8-flash-next:4bit`
  on `http://localhost:11435`, supervised by the `local.slotkeeper`
  LaunchAgent (start at login, restart after crash, 30 s throttle).
- Window is 32,768 tokens (`everyday`), prefill wait 10 minutes, vision off.
  OpenCode declares the same 32,768 context and 4,096 output.
- Startup plan on the 32K window: 19 experts/layer, 2.5 GB pool, 8.8 GB
  expected peak, versus 13/layer and 1.8 GB after shrink on the 65K window
  with the same applications open.
- First 32K measurements (cold cache, right after restart):

  | Prompt | Prompt tok | TTFT | Prefill | Decode |
  | --- | ---: | ---: | ---: | ---: |
  | short | 24 | 4.5 s | n/a | 2.6 tok/s |
  | medium | 1,673 | 71 s | 23 tok/s | 2.7 tok/s |

  Prefill ran far below the ~85 tok/s plan; the cache was cold and refilling
  from SSD. Repeat after a few hours of use before drawing conclusions.
- The monitor samples every 30 s into `~/.slotstream/metrics/`.
- Ollama remains installed on 11434 and no longer conflicts.
- Disk free rose from 14 GiB to 82 GiB after cleanup, which makes the
  `pack-experts` contiguous artifact a possible experiment again.
- Fixed 17:35 by `patches/slotstream-0.2.14-stale-pressure.patch` (installed):
  the request path now cross-checks reclaimable memory before refusing on a
  latched OS pressure level. Verified live 17:45: request served during a
  90 s simulated critical level, with the decision logged.
- Finding 17:09: a stuck kernel pressure level (left behind by a killed
  `memory_pressure -S`) made Slotstream refuse every request at tokenization
  with 65% memory free. Slotstream trusts `kern.memorystatus_vm_pressure_level`
  alone. Real-world analogue: any process that leaves the level elevated takes
  the server down until it clears. Worth a Slotstream change: cross-check the
  level against actual availability before refusing, or expose the reading in
  `/api/show` so the supervisor can flag it. The drill script now lets the
  simulator time out instead of killing it.
- Pressure drill run 17:01: simulated critical pressure during prefill produced
  the retryable error and the server-side log line. Retry contract verified.
  Side observation: with OpenCode closed the cache had grown 19 → 43
  experts/layer, then fell to 13 under simulated pressure and had not regrown
  minutes later. Watch the monitor series for regrowth behaviour.
- Done later the same day: `caffeinate -s` held by the server on AC (idle
  sleep no longer cuts an evening task), deep profile without a prefill
  deadline, OpenCode context synced on every start.
- Title generation disabled in OpenCode (`"agent": {"title": {"disable":
  true}}` in `opencode.json`, 18:35); sessions show untitled, the local server
  no longer pays a request per session. Takes effect after OpenCode restarts.
- Not yet done: a warm-cache re-benchmark, the context sweep.

## Plugin Deployment

The plugin is currently tied to this repository. The discovered OpenCode file is:

```text
~/.config/opencode/plugins/model-stats.ts
```

It contains an absolute re-export:

```ts
export { ModelStats } from "~/slotkeeper/model-stats.ts"
```

Moving or deleting the repository will therefore break the plugin on the next
OpenCode restart. A running OpenCode process may continue using code it already
loaded, which can hide the problem until later.

For this machine, the smallest robust deployment is a direct copy of
`model-stats.ts` into OpenCode's plugin directory. The tradeoff is that updates
must be installed again. If updates remain frequent, add a small installer that
runs `npm run typecheck`, copies the file, verifies the copy, and reminds the
operator to restart OpenCode.

An npm package is unnecessary for one personal machine. It becomes useful only
if the plugin is distributed or installed on multiple computers.

The plugin SDK versions should also be aligned before introducing runtime SDK
imports. This repository uses `@opencode-ai/plugin` 1.18.30, while
`~/.config/opencode/package.json` currently names 1.4.8. The current plugin's SDK
imports are type-only, so the mismatch is not affecting runtime behavior today.

## Context Recommendation

### Use 32K for the continuous profile

Adopted 2026-09-11 17:00. The 65,536-token window is supported, but it costs approximately 1.8 GB
more planned memory than 32,768 tokens. Slotstream's fixed footprint already
includes a 32K context. Above 32K it charges both additional active sequence
state and a conservative transient growth reserve.

Reducing the serving window to 32,768 therefore has three benefits:

- Recovers roughly 1.8 GB for expert cache, macOS, or other applications.
- Reduces the duration and exposure of long prefills.
- Keeps the service inside Slotstream's ordinary default and most-tested path.

Reducing below 32K can still improve latency and bound accidental prompt growth,
but does not reduce the same planned fixed footprint. A 16K profile is useful as
an operational policy, not primarily as another large memory saving.

When changing the server window, change OpenCode's provider context declaration
to the same value. Otherwise OpenCode may construct requests that the server must
refuse.

Suggested profiles:

| Profile | Context | Use |
| --- | ---: | --- |
| Everyday | 32,768 | Continuous coding and general work |
| Conservative | 16,384 | Heavy multitasking or maximum responsiveness |
| Deep context | 65,536 | Explicit sessions where long context is worth the memory |

Keep elastic auto-sizing enabled. Avoid `--memory-gb`, `--pool-gb`, and
`--experts-per-layer` for the continuous profile because explicit size settings
pin the cache and disable automatic resizing. `--max-ram-percent` may be lowered
to impose a firmer ceiling while preserving elastic behavior.

If vision is never used, `--vision off` prevents an unexpected first-image load
and its 0.9 GB resident cost. Keep MTP on `auto`; on a memory-constrained plan it
will not enable unless its measured speed tradeoff is favorable.

Before adopting a profile, stop the loaded server and compare plans:

```sh
slotstream doctor --max-context 16384 --json
slotstream doctor --max-context 32768 --json
slotstream doctor --max-context 65536 --json
```

Do not use `doctor` for feasibility while the model server is loaded. The running
process consumes the very memory the planner is trying to measure.

## Priorities

### P0: Establish a dependable baseline

Effort: hours to two days.

- Change the continuous profile to 32K and keep 65K as an intentional restart
  profile.
- Decouple the installed plugin from the repository with a verified copy/install
  command.
- Align OpenCode plugin SDK versions.
- Add log rotation for Slotstream and OpenCode logs.
- Record one week of normal-use startup plans, expert-cache resizing, failures,
  retry outcomes, TTFT, and decode rate before tuning core algorithms.
- Consider tightening the existing 30-minute `--max-prefill-wait` default to 10
  minutes. Slotstream may refuse a long prompt at admission when its estimated
  prefill cannot finish within the remaining budget; this is intentional even
  when the prompt would otherwise fit memory and context.

### P1: Supervise the service

Effort: two to five days for a solid personal setup. A first pass exists in
`scripts/slotkeeper` and `launchd/local.slotkeeper.plist`; the items
below that it does not yet cover are sleep/wake handling and failure
notifications from the supervisor itself (the monitor notifies on pressure and
disk).

- Replace ad hoc `nohup` startup with a user LaunchAgent or small supervisor.
- Start at login only if desired; otherwise expose one deterministic start
  command.
- Poll `GET /api/version` for readiness, `GET /api/ps` for process status, and
  `POST /api/show` with `{"model":"qwen3.8-flash-next:4bit"}` for plan and cache
  status.
- Restart after an actual crash with bounded backoff. Do not restart-loop on bad
  configuration, missing weights, or insufficient disk.
- Preserve and rotate stdout/stderr.
- Detect port conflicts and distinguish this server from an unrelated process.
- Handle sleep and wake explicitly, including a post-wake health check.
- Notify after repeated failure rather than silently consuming resources.

### P2: Improve Slotstream's control plane

Effort: roughly one to three weeks, depending on scope.

- Add a typed lifecycle state: loading, ready, busy, stopping, and failed.
- Expose startup phase, active request, queue depth, pressure state, last failure,
  and governor resize history.
- Add graceful drain and shutdown rather than process termination.
- Add request IDs and out-of-band cancellation.
- Add a safe administrative endpoint for dropping prefix state and requesting an
  between-request cache shrink.
- Emit structured progress and errors instead of requiring log-text parsing.
- Add an idle policy that shrinks expert and prefix caches without unloading the
  whole model. Full unload should remain optional because reload cost is high.

### P3: Build a macOS controller

Effort: about one week for a prototype, three to four weeks for a useful MVP,
and ten or more weeks for a polished distributable product.

- Begin with a menu-bar app supervising an exact Slotstream executable.
- Show state, memory profile, context profile, model readiness, activity, recent
  failures, and current cache size.
- Provide Start, Stop, Restart, Open Logs, Copy Endpoint, and profile switching.
- Keep inference in a helper process so an MLX or allocation failure cannot take
  down the menu UI.
- Add model download, resume, verification, and disk-space UX only after process
  supervision is reliable.

See `SLOTSTREAM_DEVELOPMENT.md` for the app architecture and effort breakdown.

## Further Reliability Ideas

### Pressure avoidance

- Refuse or queue a new long prefill before macOS reaches critical pressure.
- Shrink the expert cache proactively when availability trends downward rather
  than only after a pressure notification.
- Add hysteresis and cooldown telemetry so growth and shrink do not oscillate.
- Separate a small always-safe baseline cache from opportunistic extra cache.
- Detect whether a request's estimated context workspace fits before tokenization
  and before entering the single-flight generation gate.

### Workload control

- Bound queue depth and reject excess work quickly.
- Give interactive requests priority over background jobs.
- Add per-client request deadlines and cancellation IDs.
- Add a configurable idle cache shrink while retaining the loaded trunk weights.
- Consider a 32K server with explicit summarization in OpenCode instead of using
  65K for every session.

### Diagnostics

- Add a small local metrics endpoint with counters for requests, failures,
  retries, pressure interruptions, cache resizes, TTFT, and throughput.
- Record structured JSON logs with rotation instead of only human-readable text.
- Add a support-bundle command that gathers versions, plan, recent errors, and
  memory snapshots without prompts or generated content.
- Add a synthetic health inference separate from HTTP liveness, run sparingly so
  it does not contend with real work.

### Upgrade safety

- Pin Slotstream source, dependency versions, metallib, and model manifest as one
  tested release unit.
- Keep build identity and source archive beside every installed binary.
- Run patch dry-run, T0 checks, release build, hash comparison, startup, health,
  and one inference smoke test before switching versions.
- Keep the previous complete release directory for immediate rollback rather
  than replacing files in place indefinitely.

## Plan Review (2026-09-11)

The sequence in the three documents is sound: evidence before tuning, supervision
before a controller, no chat UI in the app, and no second model backend without
a concrete reason. Nothing in it needs reversing. Inspecting the live machine
did surface facts the plans do not yet account for:

- **Ollama shares the port.** `/usr/local/bin/ollama` is installed and the
  OpenCode config declares both an `ollama` and a `slotstream` provider on
  `localhost:11434`. Whichever starts first wins the port; the other fails or, if
  Ollama's app auto-starts at login, Slotstream can never bind. The control
  script now names the squatter instead of failing silently. Moving Slotstream
  to another port and updating one `baseURL` removes the ambiguity for good.
- **Disk is nearly full.** 14 GiB free on a 460 GiB volume, with 98 GB of model
  weights. Swap grows under exactly the pressure this project is trying to
  survive, and swap needs disk. The monitor alerts below a 6 GiB floor. The
  `pack-experts` contiguous artifact is not an option at this free space.
- **The Mac sleeps after one minute idle** unless something holds a
  `caffeinate` assertion. A server survives sleep, but an in-flight request is
  suspended mid-prefill and its client deadline keeps running. The supervisor
  should hold an idle-sleep assertion only while a request is active.
- **The current plan is starved.** After elastic shrink the running server holds
  13 experts/layer in a 1.8 GB pool with a ~2.7 tok/s planned warm decode; a
  measured short request decoded at 2.35 tok/s. This is the 65K window plus
  other applications competing for a 24 GB machine, and it is the strongest
  argument for the 32K experiment.
- **Pressure can be simulated.** `memory_pressure -S -l warn|critical` makes the
  kernel report a level without allocating. Slotstream reacts to the OS
  notification, so the untested retry path can be exercised on demand with
  `scripts/pressure-drill.sh`.
- **Title generation hits the local model.** After the first message in a
  session OpenCode asks the model for a short session name using a separate
  `title` agent. It is cosmetic (it labels the session list) but costs a full
  request and prefill on this server, competing for the single-flight gate.
  Fix applied: `"agent": {"title": {"disable": true}}` in `opencode.json`.
  The alternative, `small_model`, routes it to a cheaper model instead. Point OpenCode's `small_model` at a cheaper provider (or a cloud
  model) so the local server only serves real work.
- The expanded patch (25,402 T0 assertions) is now installed (16:50).

## Tooling Added (2026-09-11)

The roadmap asked for a week of evidence but had nothing to collect it. These
live in `scripts/`, `launchd/`, and `Slotkeeper/`; none of them require a
Slotstream rebuild and none were applied to the running server.

| Tool | Purpose | Status |
| --- | --- | --- |
| `scripts/slotkeeper` | start/stop/restart/status/health, named profiles, port-conflict and disk checks, log rotation, doctor guard, support bundle, LaunchAgent install | verified `status` against the live server |
| `launchd/local.slotkeeper.plist` | user LaunchAgent: restart on crash only, 30 s throttle, log capture | installed and running |
| `scripts/install-release.sh` | new release directory, hashes, atomic symlink switch, `--rollback` | used for the 16:50 install |
| `scripts/monitor.sh` | 30 s JSONL samples of pressure, swap, disk, battery, process, plan and prefix-cache state, with notifications | running in the background (restarted 17:00 for the new port) |
| `scripts/bench.py` | streaming TTFT/prefill/decode measurements with plan snapshots, tagged by label | one smoke row recorded |
| `scripts/pressure-drill.sh` | simulated pressure during prefill; asserts retryable wording | run 17:01, contract holds |
| `scripts/install-plugin.sh` | typecheck, copy, hash-verify, SDK version note | written |
| `scripts/build-slotstream.sh` (`slotkeeper patch`) | extract shipped source, apply patches idempotently, checks, build, install, restart; `--status` | verified build-only |
| `scripts/setup.sh` | new-machine setup: requirement checks, settings, plugin install, provider snippet, optional services | tested against a scratch home |
| `Slotkeeper/` | SwiftUI menu-bar prototype: state, plan, pressure, start/stop/restart, profiles, logs, bundle, exerciser status and pause | builds and runs |
| `scripts/exerciser.py` | continuous 12-task suite with per-run cost and behaviour checks; yields to OpenCode, battery, pressure, pause flag | LaunchAgent `local.slotkeeper-exerciser`, started 17:15 |
| `scripts/report.py` | folds exerciser, bench and monitor data into pass rates, medians, decode-vs-cache, pressure minutes | written |
| `slotkeeper bar install` | menu-bar app built in release and registered as LaunchAgent `local.slotkeeper-bar` (loads at login) | installed 17:32 |
| plugin `opencode-active` marker | `model-stats.ts` writes `~/.slotstream/opencode-active` during requests so the exerciser never competes | typechecks; loads on next OpenCode restart |

The plugin still loads through the repo shim on purpose while the plugin
changes daily. Switch to the copy when it settles.

## Additional Ideas

Beyond the existing P0 to P3 list, roughly in order of value per effort:

1. **Slotstream status endpoint.** A read-only `GET /api/status` (or richer
   `/api/ps`) exposing lifecycle phase, active request id, prefill progress
   (tokens done/total, ETA), queue depth, governor state and resize history,
   and last failure. The development guide rates read-only metadata as low to
   moderate difficulty. It replaces the plugin's estimated ETA with the real
   number, gives the menu-bar app a busy state, and is the first item of P2.
2. **Idle-sleep assertion.** Done as `caffeinate -s` around the server
   process: no idle sleep on AC while the server runs, normal sleep on
   battery. A request-scoped variant would let an idle server on AC sleep;
   not needed while evening runs are the goal.
3. **Battery and thermal policy.** Refuse or defer background work on battery,
   and log `ProcessInfo.thermalState` and CPU speed limit alongside decode rate
   to see whether sustained runs throttle. The monitor already records battery
   state and speed limit.
4. **Profile as single source of truth.** `~/.slotstream/profile` drives the
   server window; a small `sync-opencode` step should rewrite the provider's
   `limit.context` to match so the two cannot drift. Blocked only by the config
   being JSONC (the file currently has a trailing comma), so it needs a tolerant
   parser rather than `jq`.
5. **Prompt-budget preflight in the plugin.** Before a request, compare the
   estimated prompt against the plan's prefill rate and headroom, and warn (or
   suggest compaction) when the ETA exceeds a threshold or the prompt is within
   a few thousand tokens of the window. Pair with OpenCode compaction around
   70% of a 32K window.
6. **Structured JSON logging in Slotstream** (`--log-format json`). Moderate
   effort; makes the monitor, the app, and the support bundle robust against
   wording changes like the one the retry patch depends on.
7. **Idle cache policy.** After N idle minutes, shrink the expert pool to a
   baseline without unloading the trunk; after M hours on battery, stop. The
   first needs a Slotstream admin endpoint; the second is a supervisor rule.
8. **Weekly evidence report.** A script that folds `metrics/*.jsonl` and
   `bench.jsonl` into a short table: pressure minutes per day, resize events,
   decode rate versus experts/layer, TTFT versus prompt size, failures and
   retries. Decide profile changes from that, not from single snapshots.
9. **SSD throughput baseline.** Decode is bounded by expert reads from disk when
   the cache is small. Measure sequential read speed once (the plan assumes a
   17.3 GB/s reference) so slow decode can be attributed correctly.
10. **Separate the plugin's two roles.** Split observation (toasts, log record)
    from advice (headroom warnings, ETA) so the observation half can be
    published as a generic OpenAI-compatible-provider stats plugin.

## Recommended Next Experiment

The 32K experiment ran on 2026-09-11 (see "Where things stand"). The next one
is the context sweep, which measures TTFT against prompt size on both profiles:

```sh
scripts/exerciser.py --sweep 4000,8000,16000,24000,32000 --label everyday
scripts/slotkeeper restart deep
scripts/exerciser.py --sweep 32000,48000,64000 --label deep
scripts/slotkeeper restart everyday
```

Read the result in the dashboard's "Time to first token by prompt size" chart
or `scripts/report.py`. Decide the daytime default from that, and use it to
size the prefix-retention change.
