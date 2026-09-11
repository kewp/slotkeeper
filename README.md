# OpenCode Model Stats

An OpenCode plugin that shows live prefill timing and detailed completion stats
for a local Slotstream model.

See [SLOTSTREAM_RECOVERY.md](SLOTSTREAM_RECOVERY.md) for the implementation,
operations, validation, and recovery reference.

See [LOCAL_LLM_ROADMAP.md](LOCAL_LLM_ROADMAP.md) for the reliability roadmap
and [SLOTSTREAM_DEVELOPMENT.md](SLOTSTREAM_DEVELOPMENT.md) for context changes,
engine development, future-model support, and the macOS app proposal.

## Features

- Refreshes an elapsed-time toast every 15 seconds while waiting for first output,
  and stops it as soon as text, reasoning, or a tool call begins streaming.
- Estimates the current prompt size from the latest completed request and shows
  a cache-miss ETA using Slotstream's planned prefill rate and chunk size.
- Keeps the completed report visible for 24 hours.
- Reports prompt, cached, cache-write, output, and reasoning tokens.
- Reports context usage, prompt headroom, prompt growth, cache hit rate, TTFT,
  prefill rate, decode rate, end-to-end rate, finish reason, and total time.
- Reads Slotstream's Ollama-compatible `/api/ps` and `/api/show` endpoints for
  process resident memory, device working set, planned peak, expert residency,
  live prefix-cache counters, and planned inference rates.
- Turns failed requests into persistent diagnostic reports with the provider
  error, elapsed time, Slotstream plan/cache state, and a post-failure macOS
  memory-pressure, availability, and swap snapshot.
- Shows OpenCode's retry attempt and countdown for transient Slotstream errors.
- Writes the complete structured record to OpenCode's normal log through
  `client.app.log()`.

The OpenAI-compatible streaming protocol does not report prefill token progress,
and `/api/show` does not expose the active request's reused-prefix length. The
live prompt count and cache-miss ETA are therefore labeled as estimates; they do
not claim an exact percentage or account for a cache hit. Slotstream's own
terminal remains the only source for exact active prefill progress. TTFT and the
observed prefill rate become available when the first output arrives.

## Automatic recovery

OpenCode 1.18.30 already retries transient provider failures up to five times
with exponential backoff. Slotstream 0.2.14's streamed memory-pressure message
does not match OpenCode's retry classification, so the retry loop is not entered.

`patches/slotstream-0.2.14-opencode-retry.patch` fixes that integration contract.
It advertises automatic retry only when pressure interrupts inference before the
first model token. Pressure after output begins remains non-retryable, preventing
duplicate text or tool side effects. It also records non-cancellation request
failures on Slotstream's standard error stream.

## Install

```sh
cp model-stats.ts ~/.config/opencode/plugins/model-stats.ts
```

Restart OpenCode after installing or updating the plugin.

The default provider id is `slotstream`. Change `PROVIDER_ID` at the top of
`model-stats.ts` if your OpenCode provider uses another id. Toast durations and
the live refresh interval are configured beside it.

## Operations tooling

Alongside the plugin, the repo carries the scripts used to run Slotstream as a
continuous local service. None of them need a Slotstream rebuild.

```sh
scripts/slotstream-ctl.sh status          # process, port owner, plan, cache, pressure, profile mismatch
scripts/slotstream-ctl.sh start everyday  # 32K window; also: conservative (16K), deep (65K), or a number
scripts/slotstream-ctl.sh install-agent   # LaunchAgent: restart on crash, log capture
scripts/slotstream-ctl.sh monitor start   # 30 s JSONL samples to ~/.slotstream/metrics/ (LaunchAgent)
scripts/slotstream-ctl.sh exerciser start # continuous task suite (LaunchAgent); pause/resume/status/report
scripts/report.py --hours 24              # what the exerciser, bench and monitor recorded
scripts/bench.py --label 32k              # one-off TTFT / prefill / decode measurements
scripts/pressure-drill.sh                 # simulated memory pressure during prefill; checks retry wording
scripts/install-plugin.sh                 # standalone plugin copy (or --link for the repo shim)
```

`SlotstreamBar/` is a SwiftUI menu-bar prototype that supervises the server
through the control script and shows the exerciser's progress with a pause
button for battery: `cd SlotstreamBar && swift run`.

### Exerciser

`scripts/exerciser.py` runs a rotating suite against the server in the
background: short chat, code review of a random repo file, three-turn
conversation (checks prefix reuse), tool call, JSON answer, codebase summaries at
8K/16K/24K tokens, a 1,500-token generation, an over-window prompt (must be
refused cleanly), a client cancel mid-prefill (server must recover), and two
simultaneous requests (queueing). Every run records latency, tokens, server CPU
and RSS peaks, pressure, battery and the plan before and after, to
`~/.slotstream/metrics/exerciser.jsonl`.

It yields to real work: it waits while `~/.slotstream/opencode-active` is fresh
(the plugin writes it during requests), while on battery, while memory pressure
is critical, and while `~/.slotstream/exerciser.pause` exists (the menu-bar
Pause button). Point it at more code with `EXERCISER_REPOS=/path/a:/path/b` in
`~/.slotstream/ctl.env`.

## Development

```sh
npm install
npm run typecheck
```

## Notes

OpenCode's TUI has one toast slot. The 24-hour report remains visible while the
TUI is open, but a later OpenCode or plugin toast can replace it. The structured
log record remains available after the toast is replaced.
