# Slotstream patches

Two patches against [Slotstream](https://github.com/carloslfu/slotstream)
0.2.14 source. Apply in this order; each is independent of Slotkeeper and is a
candidate for an upstream pull request. Both pass Slotstream's T0 check suite
(`make checks`) with the new checks included.

| Patch | What it changes | New check |
| --- | --- | --- |
| `slotstream-0.2.14-opencode-retry.patch` | Pre-output memory-pressure failures say `try your request again`, which OpenCode's retry classifier recognises; post-output failures keep the non-retryable wording so a replay cannot duplicate text or tool effects. Non-cancellation request failures are logged to stderr. | assertions added to `context-serving` (queued-pressure and governor-unavailable pre-output paths) |
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
for p in slotstream-0.2.14-opencode-retry slotstream-0.2.14-stale-pressure; do
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
