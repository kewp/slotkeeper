# Slotstream and OpenCode Recovery Reference

Last verified: 2026-09-11 17:00 CEST

## Purpose

This document records one specific installation (the author's 24 GB M4 Pro).
Hashes, release directory names and measurements are that machine's. Use it
as the worked example of the procedure, not as values to copy.

This integration makes local Slotstream inference failures visible in OpenCode
and safely retries transient memory-pressure failures when doing so cannot
duplicate generated text or tool effects.

The implementation has two parts:

- `model-stats.ts` observes OpenCode events, displays live and completed request
  statistics, reports failures, and exposes OpenCode's retry countdown.
- `patches/slotstream-0.2.14-opencode-retry.patch` adjusts Slotstream's failure
  wording so OpenCode recognizes safe failures as transient, adds regression
  assertions, and logs server-side request failures to standard error.
- `patches/slotstream-0.2.14-stale-pressure.patch` (applied after the first)
  stops a latched OS pressure level from refusing requests when reclaimable
  memory is plentiful. The request path used to trust the Dispatch
  memory-pressure source alone, which only reports transitions; a level left
  elevated (a killed `memory_pressure -S`, a missed "normal" event) refused
  every request indefinitely with most of RAM free. `RequestPressurePolicy`
  admits a request when reclaimable memory is at or above a quarter of RAM
  (never below 6 GB), logs the disagreement once a minute, and fails closed
  when availability cannot be read. Real pressure leaves little reclaimable
  memory, so it still refuses. The governor's own resize logic is unchanged.

## Runtime Configuration

- OpenCode: `1.18.30`
- Slotstream: `0.2.14`
- Provider id: `slotstream`
- Base URL: `http://localhost:11435/v1` (moved off 11434 so Ollama cannot collide)
- Model: `qwen3.8-flash-next:4bit`
- Context limit: 32,768 tokens (everyday profile; `deep` = 65,536 on request)
- Output limit: 4,096 tokens
- Supervisor: LaunchAgent `local.slotkeeper` running `scripts/slotkeeper run`
- Effective server command: `slotstream serve --model qwen3.8-flash-next:4bit --port 11435 --max-context 32768 --max-prefill-wait 10 --vision off`
- Persistent settings: `~/.slotstream/ctl.env` (`SLOTSTREAM_PORT=11435`), `~/.slotstream/profile` (`everyday`)
- Server log: `~/.slotstream/slotstream.log` (rotated at 10 MB by the control script)
- Metrics: `~/.slotstream/metrics/*.jsonl` (monitor), `~/.slotstream/metrics/bench.jsonl`
- OpenCode log: `~/.local/share/opencode/log/opencode.log`

The OpenCode provider configuration is in
`~/.config/opencode/opencode.json`. The global plugin shim is
`~/.config/opencode/plugins/model-stats.ts` and re-exports the implementation
from this repository.

## Recovery Contract

OpenCode retries transient provider failures up to five times with exponential
backoff. Its retry classifier recognizes error text containing
`try your request again`.

Stock Slotstream 0.2.14 reports streamed memory pressure as `retry after memory
becomes available`, which does not enter OpenCode's retry loop. The patch changes
the behavior as follows:

- Memory pressure before the first model token includes `try your request again`.
  OpenCode can replay the same request safely because no output or tool call has
  been emitted.
- Memory pressure after output begins keeps non-retryable wording. Automatically
  replaying at that point could duplicate text or tool side effects.
- Client cancellations are not logged as server failures.
- Other request failures are written to Slotstream's standard error. With the
  documented launch command, they persist in `~/.slotstream/slotstream.log`.

The plugin does not submit replacement prompts itself. Retry ownership stays in
OpenCode's existing request loop, avoiding a second non-atomic replay mechanism.

## Observability

During prefill, the plugin refreshes a toast every 15 seconds with elapsed time,
estimated prompt size, and estimated cache-miss time. The timer stops at the
first text, reasoning, or running tool output.

After completion, the report includes:

- Prompt, cached, cache-write, output, and reasoning token counts
- Context use, prompt headroom, prompt growth, and cache hit rate
- Time to first token, prefill rate, decode rate, end-to-end rate, and total time
- Finish reason
- Slotstream process resident memory and device working set
- Planned peak memory, resident experts, cache counters, chunk size, and planned
  inference rates from `/api/ps` and `/api/show`

After failure, the report includes:

- Provider error and code
- Elapsed request time
- Slotstream process, plan, expert, and cache state
- Post-failure macOS pressure, available memory percentage, and swap state
- OpenCode retry attempt and countdown when a retry is scheduled

The plugin writes the structured record through `client.app.log()`, so the data
survives after a toast is replaced.

## Installed Build Snapshot

Installed 2026-09-11 17:42 CEST from stock 0.2.14 source plus both repo patches
(`patches/slotstream-0.2.14-opencode-retry.patch`, then
`patches/slotstream-0.2.14-stale-pressure.patch`), built with
`make checks && make build` (Xcode 26.4.1, Swift 6.3.1). T0: `34 passed, 0
failed, 0 skipped (25410 assertions)`, including the new
`request-pressure-policy` check. Startup plan on the 32K window: 30
experts/layer, 4 GB pool, 10.9 GB expected peak.

| Artifact | SHA-256 |
| --- | --- |
| `slotstream` | `8880416ad243827e9af6c129ad5bdb248118c5655ad48d41fa3c58ef37f41cb2` |
| `mlx.metallib` | `198488eb61359e953580a9c4530400feee1a06dd2f28a930a6ffa58aec66a597` |

```text
~/.slotstream/bin -> releases/slotstream-0.2.14-local-20260911174205
```

Previous releases stay under `~/.slotstream/releases/` for rollback:

- `slotstream-0.2.14-local-20260911165001`: retry patch only (`slotstream` sha
  `b1099150…9d3877b`... see git history for the full value).
- `2fd5bfab…-macos26`: the earlier partial-patch build, with the stock 0.2.14
  files kept beside it as `*.0.2.14.original`.

Roll back with `scripts/install-release.sh --rollback <release-dir>` followed by
`scripts/slotkeeper restart`.

## Validation Evidence

The source used for the currently installed build passed:

```text
33 passed, 0 failed, 0 skipped (25401 assertions)
```

The expanded patch (queued-pressure and governor-unavailable pre-output paths)
is now the installed build; see the snapshot above.

Commands used:

```sh
npm run typecheck
git diff --check
patch --dry-run -p1 < patches/slotstream-0.2.14-opencode-retry.patch
make checks
make build
curl --fail http://localhost:11434/api/version
```

Additional plugin smoke tests covered the tool-first prefill timer, ETA and
`/api/show` data, failure diagnostics, and retry-status rendering.

The simulated-pressure drill (`scripts/pressure-drill.sh`, sudo for
`memory_pressure -S -l critical`) was run against the installed build on
2026-09-11 17:01 CEST while a 1,673-token prompt was in prefill:

```text
error: insufficient_memory: memory pressure interrupted prefill commit; try your request again after memory becomes available
request failed: insufficient_memory: ...        (Slotstream stderr, from the patch)
elastic: memory pressure (warning)  — cache ~43 → ~28 experts/layer
elastic: memory pressure (critical) — cache ~28 → ~13 experts/layer
RESULT: request failed with RETRYABLE wording (OpenCode would retry). Contract holds.
```

The request failed 17.6 s in, before the first token, with the wording
OpenCode's classifier accepts, and the server-side failure line reached the
log. Both halves of the patch are therefore verified on the installed binary.
Still unverified: OpenCode's retry loop itself completing a replay against this
server (its unit test could not run from the cached checkout, see below).

The stale-pressure patch was verified live at 17:45 CEST with
`sudo memory_pressure -S -l critical -s 90`: 15 s into the window a short
request was served (TTFT 4.1 s) while the kernel level was still 4, and the
server logged `OS level still elevated but 10.7 GB reclaimable (stale threshold
6.4 GB); treating it as stale and admitting requests`. The request that was
mid-prefill when the event landed was failed with retryable wording and the
governor shed cache 32 → 13 experts/layer, as before.

The OpenCode retry unit test could not run from the cached OpenCode checkout
because its monorepo dependencies were incomplete:

```text
Cannot find module '@opencode-ai/core/effect/layer-node'
```

This does not affect the installed OpenCode package, but it remains a test gap.

## Rebuild Procedure

Apply the patch only to a stock Slotstream 0.2.14 source tree. Check the actual
target first and refuse an already-applied or reversed patch:

```sh
for p in slotstream-0.2.14-opencode-retry slotstream-0.2.14-stale-pressure; do
  patch --dry-run --forward --batch -p1 < patches/$p.patch
  patch --forward --batch -p1 < patches/$p.patch
done
cp ~/.slotstream/bin/mlx.metallib Tools/lib/mlx-0.31.1.metallib   # the archive omits the 131 MB metallib
make checks
make build
```

The installed `build-source.tar.gz` is already patched and must not receive the
patch again. The release output is under `.build/release/`.

Install into a new release directory rather than overwriting the active release.
This keeps the previous complete release available and lets the final symlink
switch happen atomically. Choose a unique release name:

```sh
release="$HOME/.slotstream/releases/slotstream-0.2.14-local-$(date +%Y%m%d%H%M%S)"
mkdir -p "$release"
install -m 755 .build/release/slotstream "$release/slotstream"
install -m 644 .build/release/mlx.metallib "$release/mlx.metallib"
install -m 644 .build/release/build-identity.json "$release/build-identity.json"
install -m 644 .build/release/build-source.tar.gz "$release/build-source.tar.gz"
shasum -a 256 "$release/slotstream" "$release/mlx.metallib" "$release/build-identity.json" "$release/build-source.tar.gz"
```

Stop the existing service after the new directory is complete and verified.
Then switch the symlink and start the new release:

```sh
ln -s "$release" "$HOME/.slotstream/bin.next"
mv -h -f "$HOME/.slotstream/bin.next" "$HOME/.slotstream/bin"
```

Restart Slotstream with persistent output, either directly or through the
control script (which also checks the port, rotates the log, and waits for
readiness):

```sh
nohup ~/.slotstream/bin/slotstream serve --max-context 65536 >> ~/.slotstream/slotstream.log 2>&1 &
# or
scripts/slotkeeper start deep
```

Then verify the process, health response, and artifact hashes. Restart OpenCode
after plugin changes so the current process loads the new plugin code.

With the LaunchAgent installed the same sequence is:

```sh
scripts/slotkeeper stop
scripts/install-release.sh <source tree>      # new release dir + symlink switch
scripts/slotkeeper start               # via launchd; waits for ready
scripts/slotkeeper status
scripts/bench.py --label <what changed>
```

## Known Limits

- OpenAI-compatible streaming does not report active prefill token progress.
- Slotstream `/api/show` does not expose the active request's reused-prefix
  length. Prompt count and cache-miss ETA are estimates until first output.
- Exact active prefill progress remains available only in Slotstream's terminal
  output unless Slotstream gains an API or SSE progress event.
- OpenCode has one toast slot. A later toast can replace the long-lived report;
  the structured log remains authoritative.
- Running `slotstream doctor` while the server has the model loaded can fail its
  memory feasibility check with a zero-token maximum. Stop the server before
  using the doctor command for package-integrity verification.
- After the drill the governor stayed at 13 experts/layer for several minutes
  with pressure back to normal and no requests. Whether regrowth waits for a
  request boundary or a cooldown is an open question; the monitor's
  `experts_per_layer` series will answer it.

## Repository History

- `c302bbe` Add OpenCode model stats plugin
- `6650f3e` Handle commands without provider context
- `a56361d` Improve live Slotstream stats
- `3cca117` Report and recover Slotstream failures
- `89a3631` Document Slotstream recovery setup
- `c4bb5d1` Add CLAUDE.md

Operational tooling (`scripts/`, `launchd/`, `Slotkeeper/`) was added on
2026-09-11; see `LOCAL_LLM_ROADMAP.md` "Tooling Added". Use
`scripts/slotkeeper bundle` to capture the state described in this file
before and after a rebuild.
