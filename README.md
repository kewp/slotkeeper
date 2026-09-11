# OpenCode Model Stats

An OpenCode plugin that shows live prefill timing and detailed completion stats
for a local Slotstream model.

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
duplicate text or tool side effects.

## Install

```sh
cp model-stats.ts ~/.config/opencode/plugins/model-stats.ts
```

Restart OpenCode after installing or updating the plugin.

The default provider id is `slotstream`. Change `PROVIDER_ID` at the top of
`model-stats.ts` if your OpenCode provider uses another id. Toast durations and
the live refresh interval are configured beside it.

## Development

```sh
npm install
npm run typecheck
```

## Notes

OpenCode's TUI has one toast slot. The 24-hour report remains visible while the
TUI is open, but a later OpenCode or plugin toast can replace it. The structured
log record remains available after the toast is replaced.
