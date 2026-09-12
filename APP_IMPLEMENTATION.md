# App Implementation Guide

Written 2026-09-11 for whoever picks this up next, human or model. It is
self-contained: it names the files, the data formats, the exact commands to
verify each step, and the traps already hit. Read `CLAUDE.md` first for the
operating rules, then this file. `APP_PLAN.md` is the vision; this is the work.

## 0. Ground rules for any implementer

- Never restart, stop, or `pkill` the Slotstream server on your own. Use
  `scripts/slotkeeper` and only when the user asks. Read-only endpoints
  are always fine: `GET /api/version`, `GET /api/ps`, `POST /api/show` with
  `{"model":"qwen3.8-flash-next:4bit"}`.
- The server port and other knobs live in `~/.slotstream/ctl.env`. Every tool
  reads it. Do not hard-code 11434 or 11435.
- Scripts run under `/bin/bash` 3.2 through launchd: no `mapfile`, no
  associative arrays, guard `lsof` under `pipefail`, make new scripts
  executable (`chmod +x`) or launchd exits with code 78.
- Reload background pieces with the control script, never `launchctl
  kickstart` (it hangs here):
  - `scripts/slotkeeper exerciser start` after editing `exerciser.py`
  - `scripts/slotkeeper monitor start` after editing `monitor.sh`
  - `scripts/slotkeeper bar restart` after editing anything in
    `Slotkeeper/` (builds release, reloads the LaunchAgent)
- Verify before claiming done:
  - `npm run typecheck` for the plugin
  - `python3 -m py_compile scripts/*.py` and `bash -n scripts/*.sh`
  - `cd Slotkeeper && swift build` for the app
  - `scripts/slotkeeper status`, `... exerciser status`, `... bar status`
- Commit on `main` with a short imperative subject. Do not create branches.
- Update the docs that describe what you changed (`README.md` command list,
  `LOCAL_LLM_ROADMAP.md` tooling table, this file).

## 1. Data contracts (read these before writing any UI)

All paths are under `~/.slotstream/`. Times are ISO-8601 UTC unless noted.

### 1.1 `ctl.env`

`KEY=value` lines. Known keys: `SLOTSTREAM_PORT` (11435), optional
`SLOTSTREAM_MODEL`, `SLOTSTREAM_MAX_RAM_PERCENT`, `SLOTSTREAM_VISION`,
`SLOTSTREAM_CAFFEINATE`, `EXERCISER_REPOS` (colon-separated), `EXERCISER_GAP_S`,
`EXERCISER_PAUSE_ON_BATTERY`, `EXERCISER_MAX_PROMPT`. Environment set by the
caller wins over the file.

### 1.2 `profile`

One word: `everyday` (32768), `conservative` (16384), `deep` (65536), or a
number. Read by the control script at start.

### 1.3 `metrics/YYYY-MM-DD.jsonl` (monitor, one line per 30 s)

```json
{"ts":"2026-09-11T15:10:12Z","pressure":"normal|warning|critical|unknown",
 "free_percent":65,"swap_used_mb":686.6,"disk_free_gb":98,
 "battery":"100 ac" | "87 battery" | null,"cpu_speed_limit":null,
 "slotstream":{"pid":82114,"rss_mb":26,"cpu_percent":0.0,"ready":true,"loaded":true,
   "size_vram_gb":4.86,"experts_per_layer":30,"pool_gb":4.0,"max_context":32768,
   "est_warm_tok_s":3.8,"est_prefill_tok_s":85,"prefix_held_tokens":0,
   "prefix_hits":1,"prefix_misses":2,"prefix_evictions":5,"notes":["..."]}}
```

`ready` is whether `/api/ps` answered; `loaded` whether it listed the model.
`rss_mb` excludes Metal memory; `size_vram_gb` is the server's own figure.

### 1.4 `metrics/exerciser.jsonl` (one line per task run)

```json
{"ts":"...","task":"code-review","label":"","cycle":3,"ok":true,"note":"",
 "elapsed_s":81.2,"ttft_s":31.4,"prefill_tok_s":52.1,"decode_tok_s":3.1,
 "prompt_tokens":1673,"output_tokens":400,"finish":"length",
 "error":null | {"code":"insufficient_memory","message":"..."} | {"status":503,"body":"..."},
 "details":{...task specific...},
 "process":{"cpu_mean":53.5,"cpu_peak":67.5,"rss_peak_mb":988,"samples":81} | null,
 "system_before":{"pressure":"normal","free_percent":66,"battery":100,"discharging":false,"swap_used_mb":686.6},
 "system_after":{...same...},
 "plan_before":{"experts_per_layer":30,"pool_gb":4.0,"est_prefill_tok_s":85,"est_warm_tok_s":3.8,
   "prefix_held":0,"prefix_hits":1,"prefix_misses":2},
 "plan_after":{...same...}}
```

Scheduling: heavy tasks run only inside `EXERCISER_HEAVY_HOURS` (default
0-7 local) or after `EXERCISER_HEAVY_IDLE_MIN` (default 30) minutes without
keyboard or mouse input; otherwise they are skipped for that cycle, and the
gap between light tasks is `EXERCISER_DAY_GAP_S` (default 600 s). The state
file's `heavy` key says which applies (`heavy allowed (hours 0-7)`,
`heavy allowed (idle 42 min)`, `heavy deferred to ...`).

Task names: `short-chat`, `code-review`, `multi-turn`, `multi-turn-long`,
`tool-call`, `json-answer`, `codebase-8k`, `codebase-16k`, `codebase-max`,
`long-generation`, `context-overflow`, `cancel-mid-prefill`,
`concurrent-pair`, and `sweep-<tokens>` from `--sweep`. `details` per task:
`code-review` has `file`; `multi-turn` and `multi-turn-long` have
`turn1_ttft_s`, `turn2_ttft_s`, `turn3_ttft_s` (the long one also `files`,
`est_prompt_tokens`, and passes only when turn 2 is at most half of turn 1); `context-overflow` has `window`, `error_code`;
`cancel-mid-prefill` has `recovery_s`; `concurrent-pair` has `wall_s`,
`ttfts`, `queued`; codebase tasks have `files`, `est_prompt_tokens`.

### 1.5 `metrics/bench.jsonl` (one-off `bench.py` rows)

`{"ts","label","prompt","prompt_chars","prompt_tokens","output_tokens","ttft_s",
"prefill_tok_s","decode_tok_s","end_to_end_tok_s","total_s","finish","error",
"before":{plan snapshot},"after":{plan snapshot}}`.

### 1.6 `exerciser.state.json` (live, rewritten atomically)

```json
{"started":"...","cycle":3,"runs":40,"ok":37,"fail":3,
 "current":"code-review"|null,"current_started":"..."|null,
 "paused":"OpenCode active (build, 62s ago)"|"on battery"|"memory pressure critical (65% free)"|"server not ready"|"paused by user"|"stopped"|null,
 "last":[{"ts","task","ok","note","ttft_s","decode_tok_s","prompt_tokens","output_tokens","elapsed_s"}, ... up to 8],
 "by_task":{"code-review":{"ok":5,"fail":0}},
 "progress":{"elapsed_s":12.3,"ttft_s":4.1,"output_tokens":38,"decode_tok_s":3.2,"prompt_tokens":1673}|null,
 "label":"","pid":88342,"updated":"..."}
```

### 1.6b `jobs/` and `calibration.json`

`~/.slotstream/jobs/{queued,running,done}/<id>.json`, one file per job, moved
between folders as it progresses; `logs/<id>.log` is the transcript;
`jobs.pause` holds the runner. Fields: `id, created, repo, task, agent, auto,
label, session, attempts, result` and, once run, `started, finished, elapsed_s,
exit_code, changed_files, commits, diff_stat`. `result` is one of `queued, ok,
failed, memory, retrying, timeout`.

`~/.slotstream/calibration.json` is the measured verdict: `headline, window,
largest_prompt_ok, comfortable_prompt, first_failure_at, ttft_median_s,
ttft_at_largest_s, prefill_median_tok_s, decode_median_tok_s, machine,
ram_percent, measured_at, finished_at, attempts[]`. The app's headline card
reads it directly; `calibrate.pause` stops the automatic runs.

### 1.7 `exerciser.pause`

Presence means paused; contents are the reason. Created by
`slotkeeper exerciser pause [reason]` or the menu bar; removed by
`resume`.

### 1.8 `opencode-active` (written by the plugin during a request)

```json
{"sessionID":"ses_...","agent":"build","modelID":"qwen3.8-flash-next:4bit",
 "startedAt":1789141630202,"estimatedPromptTokens":19726,"contextLimit":32768,
 "firstOutputAt":1789141750000,"outputChars":812,"toolCalls":2,"updatedAt":1789141760000}
```

Milliseconds since epoch. Rewritten at most once per second. Removed when the
session goes idle. Consumers must treat it as expired when `updatedAt` is
older than 10 minutes (OpenCode may have been killed).

### 1.9 Server log `slotstream.log`

Human text. The app tails this file into the Server tab as raw text; it does
**not** parse these lines into the live request view. Parsing the progress line
is the open work item that would make a long prefill legible in the app:

```
[17:47:25] prefill: reading 19726 prompt tokens, ~2.0 min to the first token at this plan (...)
[17:28:40] prefill: 4096/9125 tokens (45%), ~52 s left
[17:29:52] prefill: done, 9125 tokens in 1.9 min (80 tok/s)
elastic: memory freed — cache ~13 → ~43 experts/layer (1.8 → 5.7 GB pool, contents kept)
elastic: memory pressure (critical) — cache ~28 → ~13 experts/layer (...)
request failed: insufficient_memory: memory pressure interrupted prefill commit; try your request again after memory becomes available
memory pressure: OS level still elevated but 10.7 GB reclaimable (stale threshold 6.4 GB); treating it as stale and admitting requests
```

Timestamps are local time, no date. Rotated at 10 MB to `slotstream.log.1..5`.

### 1.10 OpenCode request records

Two sources, joined on message id by `scripts/report.py`:

- `~/.local/share/opencode/opencode.db` (SQLite, open read-only). Table
  `message`, column `data` is JSON: `providerID`, `modelID`, `agent`, `role`,
  `tokens {input, output, reasoning, cache {read, write}}`, `time {created,
  completed}` (ms), `finish`, `error {name, data {message}}`, `path.cwd`.
  Table `part` (`message_id`, JSON `data`): `type` text/reasoning/tool, with
  `time.start` (tool: `state.time.start`). TTFT = first such start minus
  `time.created`. Assistant messages with zero tokens, no error and finish
  `unknown` are empty steps; OpenCode looped 3,562 of them in three minutes
  on 2026-09-11, so count them as failures. History goes back as far as
  OpenCode keeps sessions.
- `~/.slotstream/metrics/opencode.jsonl`, one line per request written by the
  plugin (from the OpenCode restart after 2026-09-11 22:50): `ts`, `ok`, and
  the fields below. The plugin's `client.app.log` records were supposed to
  land in `~/.local/share/opencode/log/*.log`, but OpenCode 1.18 does not
  write them there, so do not read the log for them.

Fields: `extra` carries `sessionID, messageID, modelID, agent, finish, contextLimit,
contextUsedPercent, promptTokens, promptDelta, freshInputTokens,
cachedInputTokens, cacheWriteTokens, cacheHitRate, outputTokens,
reasoningTokens, ttftMs, decodeMs, totalMs` plus the runtime plan and prefix
counters; error records add `errorCode, errorMessage, elapsedMs, pressure,
availableMemoryPercent, swapUsedMB`.

### 1.11 Server API fields the app uses

`POST /api/show` → `details.memory_plan`: `experts_per_layer_cached, pool_gb,
expected_peak_gb, target_gb, device_ram_gb, device_working_set_gb,
est_prefill_tok_s, est_warm_tok_s, prefill_chunk, max_context_tokens,
implementation_context_limit, max_prefill_wait_minutes, prefix_cache_max_tokens,
runtime_prefix_cache_enabled, fully_resident, notes[]`;
`details.prefix_cache`: `enabled, held_tokens, held_gb, max_tokens, hits,
misses, evictions, conversations`. `GET /api/ps` → `models[0].size_vram`.

## 2. App code map (`Slotkeeper/`)

Packaging (2026-09-12): `scripts/build-app.sh` builds the release binary into a
real bundle at `~/Applications/Slotkeeper.app` with an Info.plist and a rendered
icon, and `slotkeeper bar install|restart` points the LaunchAgent at the
executable inside it with `SLOTKEEPER_BACKGROUND=1`, so login start stays quiet
while opening the app by hand shows the dashboard. The activation policy is
`.regular`, and `AppDelegate.applicationShouldHandleReopen` brings the window
back when the Dock icon is clicked.

- `Package.swift`: tools 5.10, macOS 14, `-parse-as-library`.
- `Sources/Slotkeeper/SlotkeeperApp.swift`: `@main` app with a
  `MenuBarExtra` and a `Window("Slotstream Dashboard", id: "dashboard")`.
  `StatusModel` (`@MainActor`, `ObservableObject`) polls every 2 s: version,
  plan (`/api/show`), system pressure (`sysctl`, `memory_pressure`), exerciser
  state file, `opencode-active`, server CPU (`ps`), last prefill line from the
  log. `StatusModel.settings` merges `ctl.env` and `SLOTSTREAM_*` env.
  `run(_:_:)` shells out to `slotkeeper` (path from
  `SLOTSTREAM_CTL` or resolved relative to the source file).
  `Shell.run` and `Http.get/post` are the only side-effect helpers.
- `Sources/Slotkeeper/Dashboard.swift`: `DashboardView` loads
  `metrics/*.jsonl` and `exerciser.jsonl` on appear and on window change,
  renders Swift Charts (cache/pressure timeline, TTFT by prompt size, decode by
  cache size), a `Table` of recent runs, and a per-task summary.
- Build/run: `swift build`, `swift run` for a dev instance (kill the launchd
  one first with `slotkeeper bar uninstall`, reinstall after).

Conventions: keep all parsing in `StatusModel`/`load()`; views are dumb. No
new dependencies without a reason; Swift Charts and Foundation cover Stage A
and B. Never import MLX or Slotstream into the app.

## 3. Stage A: Observe

### A1. Requests table (est. 1 day)

Done 2026-09-12: the dashboard is three tabs — Your work, Jobs, System.
`DashboardView.yourRequests` shows counts, a TTFT-by-prompt chart coloured by
cold versus follow-up, the follow-up/cold median comparison, and a table of the
last 80 requests. The Jobs tab queues a task (repo, text, `--auto`), lists every
job with state, elapsed, files changed and a link to its log, and the menu bar
carries a jobs section with pause/resume and daemon install. It shells out to
`scripts/report.py --requests --json --hours N` (resolved next to
`SLOTSTREAM_CTL`) and never opens the database itself. Remaining in A1: filters,
click-through to a single request, and joining the plugin's exact TTFT.

Source correction (2026-09-12): read OpenCode's own database, not the plugin's
log, which OpenCode never writes. `scripts/report.py` has the working query and
the field map is in 1.10; the plugin's `metrics/opencode.jsonl` joins on message
id for the exact TTFT and the plan at the time.

Goal: one table of every request, from any client.

1. Add `Sources/Slotkeeper/RequestsStore.swift` with
   `struct RequestRow: Identifiable { id, ts, source ("opencode"/"exerciser"/"bench"), agentOrTask, promptTokens, cachedTokens, outputTokens, ttft, prefillRate, decodeRate, totalS, finish, errorCode, expertsBefore, pressure }`.
2. Loader: parse `exerciser.jsonl` and `bench.jsonl` (see 1.4, 1.5) and the
   plugin records (1.10). For plugin records, `ts` is the log line's
   timestamp; `promptTokens = extra.promptTokens`, `cachedTokens =
   extra.cachedInputTokens`, `ttft = extra.ttftMs/1000`, `decodeRate =
   outputTokens / (decodeMs/1000)`.
3. Dashboard tab "Requests": `Table` sorted by time desc, filter by source and
   task, a detail pane showing the raw JSON.
4. Verify: the row for the last `bench.py --set short` run appears with the
   same TTFT the script printed.

### A2. Timeline with request spans (est. 1 day)

1. In `DashboardView`, add `RectangleMark` spans per request from A1 (start =
   `ts - totalS`, end = `ts`) on the cache/pressure chart, coloured by source.
2. Add swap and free-percent as a second chart sharing the x-domain.
3. Verify: a pressure event in the log lines up with a shaded band and a
   failed request span.

### A3. SQLite import (est. 1 day, do when files pass ~5 MB)

1. Use `SQLite3` from the system (`import SQLite3`), one file
   `~/.slotstream/metrics.sqlite`, tables `monitor`, `runs`, `requests` with
   the columns above and an `imported_from, line_no` pair for idempotence.
2. On launch and every 5 minutes, import new lines only (track file size per
   file in a `sources` table).
3. Charts read SQLite; JSONL stays the write format for the scripts.

### A4. Menu-bar polish (est. half a day)

- Icon states: off (grey brain), loading (hourglass), ready (brain + N/L),
  busy (brain + "…" while a request is active), pressure warning (triangle).
- Tooltip with one-line summary.
- "Copy report" item: runs `scripts/report.py --hours 24` and copies the text.

## 4. Stage B: Control

### B1. Exerciser editor (est. 1 to 2 days)

1. Exerciser reads `~/.slotstream/exerciser.config.json` if present:
   `{"tasks":{"code-review":{"enabled":true,"weight":2}, ...},"gap_s":90,"repos":[...],"custom":[{"name":"my-task","prompt_file":"/path","max_tokens":300}]}`.
   Implement in `exerciser.py`: load at startup and at the top of every cycle,
   apply enabled/weight, register custom tasks as `t_custom(name, file,
   max_tokens)` that behave like `code-review` with the file's text as prompt.
2. App: form bound to that JSON; "Run now" button calls
   `scripts/slotkeeper exerciser run-task <name>` (add that subcommand:
   `python3 exerciser.py --task <name>` while the daemon is paused; simplest is
   to write the pause flag, run, remove it).
3. Verify: disable a task, watch the next cycle skip it (state `by_task`).

### B2. Experiments (est. 2 days)

1. Sweep from the app: fields sizes + label → runs
   `exerciser.py --sweep ... --label ...` as a child process, streams stdout
   into a log pane, table of results when done.
2. Profile A/B: pick two profiles; the app pauses the exerciser, runs
   `slotkeeper restart <p1>`, waits ready, sweeps, repeats for `p2`,
   restores the original profile, resumes. Chart both labels on TTFT-by-size.
   Requires explicit user confirmation each time (it restarts the server).
3. Evening run: a "keep awake and run for N hours" toggle that writes
   `EXERCISER_GAP_S` into `ctl.env` and reloads the exerciser; the server's
   `caffeinate -s` already keeps the Mac awake on AC.

### B3. Server tab (est. 1 to 2 days)

- Profile picker with "apply and restart" (confirm dialog), showing the
  OpenCode sync result.
- Releases list from `~/.slotstream/releases/` with the active one marked;
  "Roll back" runs `install-release.sh --rollback <dir>` then restart.
- "Rebuild from source": runs `scripts/build-slotstream.sh --yes` and streams
  its output to a pane (it extracts the shipped source, applies
  `patches/*.patch`, runs `make checks && make build`, installs as a new
  release and restarts). Takes about 5 minutes. `--status` gives the patch
  state for the Server tab.
- Log viewer: tail with a filter box; highlight `request failed` and
  `memory pressure` lines.
- Support bundle button (exists in the menu).

### B4. Health tab (done 2026-09-12)

Shipped: LaunchAgent rows for all five services, disk free against the 6 GiB
floor, battery and what yields on it, the sleep assertion, and a stuck-level
note that prints the reset command when the kernel level is elevated while
memory is free. The Server tab alongside it shows `patch --status`, the release
list with the rollback command, and a filterable tail of the server log.

Original plan:

- LaunchAgent rows: server, monitor, exerciser, bar; installed/loaded/pid.
- Disk free with the 6 GiB floor, battery state and the pause policy.
- Stuck-level detector: `kern.memorystatus_vm_pressure_level` elevated while
  `free_percent` > 50 for more than 2 minutes → show the reset command
  `sudo memory_pressure -S -l warn -s 1` with a copy button.

## 5. Stage C: Understand (needs Slotstream changes)

### C1. Slotstream `/api/status` endpoint (Slotstream, est. 2 to 3 days)

Read-only, no wire changes to existing endpoints. Files: `Server.swift`
(route), `Engine.swift` (a `StatusSnapshot` struct published under a lock),
`RequestControl.swift` (progress counters), `Governor.swift` (resize history
ring buffer of 32 entries). Fields:

```json
{"phase":"loading|ready|busy|stopping","active":{"id":"...","started_at":"...","phase":"tokenize|queue|prefill|decode","prompt_tokens":19726,"prefilled_tokens":8192,"eta_s":52,"output_tokens":0},
 "queue_depth":1,"pressure":{"os_level":"critical","reclaimable_gb":10.7,"stale":true},
 "governor":{"experts_per_layer":30,"pool_gb":4.0,"last_resize":{"at":"...","from":13,"to":30,"reason":"memory freed"},"history":[...]},
 "last_failure":{"at":"...","code":"insufficient_memory","message":"..."}}
```

Add a T0 check that builds the snapshot from injected state. Then: the app
replaces log parsing with this; the plugin replaces its ETA estimate with
`eta_s`.

### C2. Full-window prefix retention (Slotstream, est. 2 to 4 days)

Status 2026-09-11 19:22: done and installed as
`patches/slotstream-0.2.14-prefix-retention.patch` (steps 1 to 4 below,
carried on `RuntimeAllocationPolicy.prefixCacheTokens` rather than a new
planner parameter, so it flows through the governor for free) plus the
`multi-turn-long` exerciser task (step 5). Checks pass; the live plan holds
32768 tokens. Qualification with `multi-turn-long` still pending; see
`patches/README.md` Status.

Today `Planner.prefixCacheTokensFor(poolBudgetGB:contextCap:)` in
`Sources/Slotstream/Plan.swift` (line ~485) returns 10% of the pool budget
converted to tokens, capped at the window. Change:

1. Add `--prefix-cache-tokens <n|full>` to `serve` in
   `Sources/slotstream-cli/main.swift`; plumb through `ModelOptions` to the
   planner request (grep `prefixCacheTokens`, 26 sites).
2. In the planner, when set, use `min(n, contextCap)` and charge
   `prefixCacheCostGB(tokens:)` against the pool budget before sizing experts,
   so the plan stays honest. Refuse at startup if it does not fit.
3. Report it in `/api/show` (`prefix_cache_max_tokens` already exists).
4. Extend the T0 `prefix-client-capacity` check with the explicit setting and
   the "does not fit" refusal.
5. Qualify with the exerciser's `multi-turn` task: turn-2 TTFT must be well
   below turn-1 at 20K+ conversations. Add a `multi-turn-long` task that
   builds a 20K-token conversation.

### C3. Structured logging (Slotstream, est. 1 to 2 days)

`--log-format json` writing one JSON object per line with `ts, level, event,
fields`. Keep the text format the default until the app reads JSON.

### C4. Correctness tracking (est. 2 days)

- Plant a known bug in a fixture file for `code-review` and score whether the
  review mentions it (string match on the function name and a keyword).
- Score `tool-call` argument validity and `json-answer` schema already; add
  a `summary-facts` task with a fixture whose summary must contain three known
  facts.
- Store `score` (0..1) in the row; chart score over time and by profile.

### C5. Cost model (est. 1 day)

Fit `ttft = a + prompt_tokens / prefill_rate` per cache size bucket from the
runs table; show predicted minutes for a given prompt size on the current
plan in the menu bar and in the plugin's prefill toast (the plugin can read a
small `~/.slotstream/model.json` the app writes).

## 6. Stage D: Product (only if wanted)

Signing and notarisation with a bundled helper, model download UX, updates.
See `SLOTSTREAM_DEVELOPMENT.md` "Native macOS App" for the constraints. Not
needed for personal use.

## 7. Known traps

- `launchctl bootstrap` right after `bootout` fails with an opaque I/O error;
  `install_side_agent` in the control script waits and retries. Reuse it.
- The OpenCode config is JSONC with a trailing comma; `jq` fails on it.
  `sync_opencode` does a targeted text edit inside the `"slotstream"` block.
- `memory_pressure -S` without `-s` leaves the kernel level stuck when killed.
  Always pass `-s <seconds>` and let it finish.
- The exerciser's `pause_reason()` calls `memory_pressure`, which takes about
  a second; do not call it more than every few seconds.
- `pgrep -f "slotstream serve"` also matches a `caffeinate -s ... slotstream
  serve` wrapper; the control script's `server_pids` handles that, prefer it.
- The plugin loaded in a running OpenCode does not change until OpenCode
  restarts; the shim in `~/.config/opencode/plugins/` re-exports this repo.
- SwiftUI `MenuBarExtra` apps run with accessory activation policy; call
  `NSApplication.shared.activate(ignoringOtherApps: true)` when opening a
  window or it appears behind other apps.
