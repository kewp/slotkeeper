# Slotstream and OpenCode Recovery Reference

Last verified: 2026-09-11

## Purpose

This integration makes local Slotstream inference failures visible in OpenCode
and safely retries transient memory-pressure failures when doing so cannot
duplicate generated text or tool effects.

The implementation has two parts:

- `model-stats.ts` observes OpenCode events, displays live and completed request
  statistics, reports failures, and exposes OpenCode's retry countdown.
- `patches/slotstream-0.2.14-opencode-retry.patch` adjusts Slotstream's failure
  wording so OpenCode recognizes safe failures as transient, adds regression
  assertions, and logs server-side request failures to standard error.

## Runtime Configuration

- OpenCode: `1.18.30`
- Slotstream: `0.2.14`
- Provider id: `slotstream`
- Base URL: `http://localhost:11434/v1`
- Model: `qwen3.8-flash-next:4bit`
- Context limit: 65,536 tokens
- Output limit: 4,096 tokens
- Server command: `~/.slotstream/bin/slotstream serve --max-context 65536`
- Server log: `~/.slotstream/slotstream.log`
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

The verified process after the final restart was PID `66629`; treat the PID as a
point-in-time value. The health endpoint returned `{"version":"0.2.14"}`.

Installed and release artifact SHA-256 values matched:

| Artifact | SHA-256 |
| --- | --- |
| `slotstream` | `78c14d82269f521adab1a8fff1b4da2acaaacfc49713ac5f8eb91ee359e8cce9` |
| `mlx.metallib` | `198488eb61359e953580a9c4530400feee1a06dd2f28a930a6ffa58aec66a597` |
| `build-identity.json` | `385ad3992a4bc2d78ad09847e7828fd39aa5a0c23c6bab3272eb0af5547a1ca8` |
| `build-source.tar.gz` | `12b8c0dce15aa08d07da632e7abff459254fdf252e8ca4f88227fd94e2a0e460` |

The installation directory is a release symlink:

```text
~/.slotstream/bin -> releases/2fd5bfab8073b29095148274b0e5857a43dc20bc530bcacb4c9180ccc5ac2b52-macos26
```

Stock backups are retained beside the installed files:

```text
~/.slotstream/bin/slotstream.0.2.14.original
~/.slotstream/bin/build-identity.json.0.2.14.original
~/.slotstream/bin/build-source.tar.gz.0.2.14.original
```

## Validation Evidence

The source used for the currently installed build passed:

```text
33 passed, 0 failed, 0 skipped (25401 assertions)
```

The maintained patch was subsequently expanded to cover the queued-pressure and
governor-unavailable pre-output paths. That source passes 25,402 T0 assertions
and the patch applies forward to clean 0.2.14 source. It has not yet replaced the
running binary because an active inference run was left undisturbed. Build and
install it during the next controlled restart, then update the artifact hashes
in this snapshot.

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
patch --dry-run --forward --batch -p1 < /Users/karl/opencode-model-stats/patches/slotstream-0.2.14-opencode-retry.patch
patch --forward --batch -p1 < /Users/karl/opencode-model-stats/patches/slotstream-0.2.14-opencode-retry.patch
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

Restart Slotstream with persistent output:

```sh
nohup ~/.slotstream/bin/slotstream serve --max-context 65536 >> ~/.slotstream/slotstream.log 2>&1 &
```

Then verify the process, health response, and artifact hashes. Restart OpenCode
after plugin changes so the current process loads the new plugin code.

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
- Server-side failure logging compiled and passed the full check suite, but the
  final installation was not deliberately forced into memory pressure merely to
  generate a production log entry.

## Repository History

- `c302bbe` Add OpenCode model stats plugin
- `6650f3e` Handle commands without provider context
- `a56361d` Improve live Slotstream stats
- `3cca117` Report and recover Slotstream failures

The logging and documentation changes after `3cca117` may remain uncommitted;
check `git status` before preparing a release or commit.
