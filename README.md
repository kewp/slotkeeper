# OpenCode Model Stats

An OpenCode plugin that shows live prefill timing and detailed completion stats
for a local Slotstream model.

## Features

- Refreshes an elapsed-time toast every 15 seconds while waiting for first output.
- Keeps the completed report visible for 24 hours.
- Reports prompt, cached, cache-write, output, and reasoning tokens.
- Reports context usage, prompt headroom, prompt growth, cache hit rate, TTFT,
  prefill rate, decode rate, end-to-end rate, finish reason, and total time.
- Reads Slotstream's Ollama-compatible `/api/ps` endpoint for model memory,
  device working set, planned peak, expert residency, prefix cache, and planned
  inference rates.
- Writes the complete structured record to OpenCode's normal log through
  `client.app.log()`.

The OpenAI-compatible streaming protocol does not report prefill token progress.
The live status can therefore show elapsed time and runtime memory, but not an
honest percentage complete. TTFT and actual prefill rate become available when
the first output arrives.

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
