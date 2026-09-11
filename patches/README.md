# Slotstream patches

Five patches against [Slotstream](https://github.com/carloslfu/slotstream)
0.2.14 source. Apply in this order (alphabetical, which is what
`scripts/slotkeeper patch` does); each is independent of Slotkeeper and is a
candidate for an upstream pull request. All four apply cleanly to a stock
0.2.14 tree in that order (verified 2026-09-12) and pass Slotstream's T0
check suite (`make checks`, 34 checks, 25,450 assertions) with the new
checks included.

| Patch | What it changes | New check |
| --- | --- | --- |
| `slotstream-0.2.14-opencode-retry.patch` | Pre-output memory-pressure failures say `try your request again`, which OpenCode's retry classifier recognises; post-output failures keep the non-retryable wording so a replay cannot duplicate text or tool effects. Non-cancellation request failures are logged to stderr. | assertions added to `context-serving` (queued-pressure and governor-unavailable pre-output paths) |
| `slotstream-0.2.14-prefix-retention.patch` | `serve --prefix-cache-tokens <n\|full>` (or `SLOTSTREAM_PREFIX_CACHE_TOKENS`) sets how much conversation state the prefix cache may retain. The planner caps it at the context window, charges it against the expert pool before sizing experts, refuses at startup if the pool would fall below its floor, and reports it in `/api/show` as `runtime_prefix_cache_tokens`. The governor keeps the explicit ceiling across resizes. | assertions added to `prefix-client-capacity` (window cap, pool charge, peak unchanged, `--no-prefix-cache` precedence, invalid values, governor shed, refusal at the floor) |
| `slotstream-0.2.14-pressure-ceiling.patch` | After an OS pressure event the elastic governor remembers the pool that met it, and for 20 minutes will not regrow past 1 GB below it. Repeated events ratchet the ceiling down; an availability shrink is never blocked; the ceiling is forgotten after the window. | assertions added to `governor-check` (regrowth capped, reason string, cooldown still applies, forgotten after the window, no effect when above the replan, dead-band respected, shrink unaffected, ratchet) |
| `slotstream-0.2.14-resume-after-refusal.patch` | A request refused between prefill passes keeps the prefix it had already committed, so the client's retry resumes instead of re-reading the whole prompt, and the server logs how many tokens it kept. Execution errors still keep nothing. A governor shrink no longer drops a large retained prefix before it sheds the expert pool. | assertions added to `prefix-client-capacity` (which failure codes keep a boundary, controller state) and `governor-check` (drop order at and above the floor) |
| `slotstream-0.2.14-stale-pressure.patch` | The request path no longer refuses on the OS pressure latch alone. `RequestPressurePolicy` admits a request when reclaimable memory is at least a quarter of RAM (never below 6 GB), fails closed when availability cannot be read, and logs the decision once a minute. | `request-pressure-policy` (8 assertions) |

## Apply and build

The one-command way, from the source archive that ships beside the installed
binary (`~/.slotstream/bin/build-source.tar.gz`):

```sh
~/slotkeeper/scripts/slotkeeper patch
```

It refuses versions other than 0.2.14, skips patches that are already
present, runs `make checks`, builds, asks before restarting, installs as a new
release directory and keeps the old one for rollback.

Manually:

```sh
tar -xzf build-source.tar.gz            # or a stock 0.2.14 checkout
cd <source>
for p in slotstream-0.2.14-opencode-retry slotstream-0.2.14-prefix-retention slotstream-0.2.14-pressure-ceiling slotstream-0.2.14-resume-after-refusal slotstream-0.2.14-stale-pressure; do
  patch --dry-run --forward --batch -p1 < ~/slotkeeper/patches/$p.patch
  patch --forward --batch -p1 < ~/slotkeeper/patches/$p.patch
done
mkdir -p Tools/lib && cp ~/.slotstream/bin/mlx.metallib Tools/lib/mlx-0.31.1.metallib
make checks && make build
~/slotkeeper/scripts/slotkeeper stop
~/slotkeeper/scripts/install-release.sh "$PWD"
~/slotkeeper/scripts/slotkeeper start
```

Never apply a patch to an already patched tree, and never accept `patch`'s
offer to reverse. `install-release.sh` keeps the previous release for
`--rollback`.

## Why each exists

**Retry wording.** OpenCode 1.18 retries transient provider errors up to five
times when the message contains `try your request again`. Stock Slotstream
says `retry after memory becomes available` for every memory-pressure
interruption, so the loop never engages. Replaying is only safe before the
first model token; after that, text or tool calls may already have reached the
client. The patch distinguishes the two.

**Stale pressure.** `DispatchSource.makeMemoryPressureSource` reports
transitions. The engine latched "pressure" on a warning or critical event and
cleared it only on a normal event. If the level stays elevated after the
condition has passed, a killed `memory_pressure -S` simulator being the easy
reproduction, every request is refused at tokenization with most of RAM free,
indefinitely. Verified on 2026-09-11: with the kernel level held at critical
for 90 seconds and 10.7 GB reclaimable, stock behaviour refused; with the
patch, requests were served and the log read `OS level still elevated but 10.7
GB reclaimable (stale threshold 6.4 GB); treating it as stale and admitting
requests`. Real pressure leaves little reclaimable memory, so it still refuses,
and the governor's shed-on-event behaviour is untouched.

**Prefix retention.** Stock Slotstream sizes the prefix cache at a tenth of
the pool budget. On a 24 GB machine with a 32K window that is about 12,000
tokens across all held conversations (`0/11940 tok held` in
`slotkeeper status`), so any coding-agent conversation longer than that is
evicted on every turn and each follow-up re-prefills the whole history at
tens of tokens per second. On 2026-09-11 the everyday profile logged 7
misses and 12 evictions against 1 hit. A full 32K window costs 0.9 GB plus
a fixed 0.34 GB for the extra entries, roughly 9 experts per layer of
decode capacity, which is a good trade when follow-up turns are the common
case. The patch makes the ceiling a knob and keeps the memory ledger honest
about it: the pool shrinks by exactly what retention grows, so the expected
peak does not move, and a setting that would push the pool below its floor
is refused before the model loads. Use it with
`SLOTSTREAM_PREFIX_CACHE_TOKENS=full` in `~/.slotstream/ctl.env`; the
exerciser's `multi-turn-long` task (20K-token conversation, turn-2 TTFT must
be at most half of turn-1) is the qualification.

**Pressure ceiling.** The governor grows when idle availability says a
fresh start would pick a bigger pool, after 60 seconds of calm. Idle
availability cannot see the several GB a long prefill needs, so on
2026-09-11 it regrew 30 to 62 and 35 to 56 experts per layer right after
pressure shrinks, and the next 8K and 24K prefills failed at prefill commit
both times. Decode speed barely depends on the pool in that range (3.05
tok/s median at 25 per layer, 3.42 at 43), so holding a smaller pool for a
while after pressure is cheap and removes the oscillation.

**Resume after a refusal.** Measured on the deep (65,536) profile on
2026-09-12: a 56K prompt was refused 19 minutes in, at 76% of its prefill,
by the admission check between passes, with the machine at normal pressure
throughout. All 19 minutes were lost, and the retry would have repeated
them. The state at that moment sits exactly on a whole-stack commit
boundary, which is the same thing the cancellation path already publishes to
the prefix cache, so the fix is to publish it for boundary-safe failures
too. The governor change is the same argument: at a long window, rebuilding
a 48K prefix costs 16 minutes while the expert pool it was sacrificed for
refills from SSD as requests run.

## Upstream pull request text

### PR 1: Advertise retry only for safe pre-output memory-pressure failures

> OpenAI-compatible clients such as OpenCode classify errors containing
> "try your request again" as transient and replay the request. Slotstream's
> memory-pressure interruptions currently use "retry after memory becomes
> available" everywhere, so those clients give up after the first pressure
> event even when a replay would be safe.
>
> This change advertises retry only when pressure interrupts a request before
> the first model token (tokenization, queue, prefill, prefill commit, and the
> governor-unavailable path). After output has started the wording is
> unchanged, because a replay could duplicate text or tool side effects.
> Non-cancellation request failures are also written to stderr so an operator
> can see them without a client log.
>
> Tests: assertions added to the `context-serving` T0 check covering the
> queued-pressure and governor-unavailable pre-output paths. `make checks`
> passes (33 checks, 25,402 assertions at the time).

### PR 2: Cross-check reclaimable memory before refusing on a latched OS pressure level

> The request path refuses work while `osPressure` is set, and that flag is
> only cleared by a `.normal` event from the memory-pressure source. If the
> kernel level stays elevated after the actual pressure has passed (for example
> a `memory_pressure -S` simulation killed before it reset, or a missed normal
> event), the server refuses every request at tokenization while most of RAM
> is free, until the process restarts.
>
> This adds `RequestPressurePolicy`: when the latch is set, read
> `Planner.deviceAvailableGB()` (free + purgeable + file cache, the same
> figure the planner uses) and admit the request if at least
> `max(6 GB, 25% of RAM)` is reclaimable. Unreadable or non-finite
> availability fails closed. A stderr line, rate-limited to once a minute,
> records the decision either way. Real pressure leaves little reclaimable
> memory, so refusals under genuine overcommit are unchanged, and the
> governor's resize-on-event behaviour is not touched.
>
> Tests: new T0 check `request-pressure-policy` (8 assertions: no pressure,
> unreadable and non-finite availability, real pressure, stale latch,
> threshold floor and scaling, threshold edge). Verified live on a 24 GB M4
> Pro with a 90-second simulated critical level: request served, decision
> logged.

### PR 3: Let `serve` choose how much conversation state the prefix cache retains

> `Planner.prefixCacheTokensFor` sizes prefix retention at a tenth of the
> pool budget. On a small machine that is a few thousand tokens shared by
> every held conversation, so a chat client whose history is longer than
> that never gets a hit: each turn evicts the previous state and re-prefills
> the whole conversation. On a 24 GB Mac with a 32K window the ceiling is
> about 12K tokens and a typical coding-agent session sees only misses.
>
> This adds `--prefix-cache-tokens <n|full>` to `serve` (also
> `SLOTSTREAM_PREFIX_CACHE_TOKENS`), carried on `RuntimeAllocationPolicy`
> next to the existing prefix-cache and prefill-chunk controls. The planner
> caps the value at the context window, charges `prefixCacheCostGB` against
> the pool before sizing experts so the expected peak is unchanged, and
> refuses a value that would push the pool below its floor before the model
> loads. `--no-prefix-cache` still wins. The governor's live controls keep
> the explicit ceiling across resizes (a pressure shed still drops the held
> state first, as before); auto retention is unchanged when the flag is not
> given. `/api/show` reports `runtime_prefix_cache_tokens`.
>
> Tests: assertions added to the `prefix-client-capacity` T0 check: full is
> capped at the window, the pool pays for it within one expert record, the
> expected peak does not rise, an explicit count is honoured, disabled
> retention wins, invalid values are refused, the governor keeps the ceiling
> on a shed, and full at the floor plan is refused.

### PR 4: Do not regrow straight back to a pool that just met memory pressure

> After an OS pressure event the governor sheds a chunk of the expert pool,
> then regrows as soon as 60 seconds pass and idle availability allows it.
> Availability sampled between requests does not include the transient
> memory of the next long prefill, so the pool can grow back past the size
> that just triggered pressure, and the next long prompt fails with a
> pressure interruption at prefill commit. On a 24 GB M4 Pro this happened
> twice in one 20-minute sweep (30 to 62 and 35 to 56 experts per layer).
>
> This remembers the pool that was live when the last pressure event fired.
> For 20 minutes (`GovernorPolicy.pressureMemory`) growth may not exceed 1 GB
> below it; repeated events ratchet the ceiling down; after the window it is
> forgotten and the plain replan resumes. Shrinking on availability is
> unaffected, and the grow dead-band still applies to the capped target. The
> resize reason says when growth was capped.
>
> Tests: assertions added to `governor-check` covering the capped regrowth,
> its reason string, the unchanged cooldown, expiry, a ceiling above the
> replan, the dead-band, an availability shrink with a ceiling set, and the
> ratchet.

### PR 5: Keep the committed prefix when a request is refused at a pass boundary

> A long prefill can be refused between passes, by the admission check or a
> pressure interruption, after most of the prompt has already been read. The
> state then sits on a whole-stack commit boundary and is still valid, but it
> is discarded, so the client's retry re-reads the prompt from the start. On a
> 24 GB M4 Pro at a 65,536-token window, a 56K prompt was refused 19 minutes
> in at 76%; the retry would have paid all of it again, and can fail at the
> same place indefinitely.
>
> `RequestFailure.retainsCommittedPrefix` names the failures raised at a
> boundary rather than inside a forward (memory, wait and deadline refusals,
> client cancellation, context length). For those, the prefill's early-exit
> path publishes `promptIds.prefix(i)` to the prefix cache exactly as the
> cancellation path already does, guarded by the same `state.tokenCount == i`
> plus `committedBoundaryValid`. Execution errors keep nothing, as before.
> The server logs how many tokens it kept.
>
> The governor also no longer drops retained conversations on every shrink.
> `shouldDropRetainedPrefix` keeps them when more than 8,192 tokens are held
> and the pool has not reached its floor, because a long prefix costs minutes
> of prefill to rebuild while the pool refills from SSD as requests run.
>
> Tests: assertions added to `prefix-client-capacity` (per-code retention,
> controller state after a refusal versus an execution error) and
> `governor-check` (drop order at, above and at the boundary of the protected
> size).

## Status

2026-09-12 00:41: all five patches installed as release
`slotstream-0.2.14-local-20260912004057`, on the deep (65,536) profile.

2026-09-11 22:42: the first four installed as release
`slotstream-0.2.14-local-20260911224202`. `ctl.env` also sets
`SLOTSTREAM_MAX_RAM_PERCENT=45` (see `LOCAL_LLM_ROADMAP.md` for the sweep
that motivated it). With that cap the governor has little room to
oscillate, so the pressure ceiling is a second line of defence; it matters
most if the cap is raised or removed.

2026-09-11 19:22: all three patches built, checked and installed as release
`slotstream-0.2.14-local-20260911192148`; `SLOTSTREAM_PREFIX_CACHE_TOKENS=full`
is in `~/.slotstream/ctl.env`. First plan after restart: 43 experts/layer,
5.7 GB pool, `prefix_cache_max_tokens` 32768 (was 11940). `/api/show`
reports `runtime_prefix_cache_tokens: 65536`, the raw `full` setting; the
plan caps it at the window. The `multi-turn-long` qualification has not run
yet; the exerciser was restarted to pick it up.

Build trap: after adding a stored field to `RuntimeAllocationPolicy`, an
incremental `swift build` left `SlotstreamTestKit` compiled against the old
layout of `GovernorPolicy.Inputs`, and `openai-context-budget` failed with a
nonsense reason (`memory pressure (warning)` from a nil field). Cleaning
`.build/arm64-apple-macosx/debug` and rebuilding fixed it. `scripts/slotkeeper
patch` always starts from a clean tree, so it does not hit this.
