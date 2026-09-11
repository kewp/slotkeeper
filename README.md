# Slotkeeper

Keep a local LLM running on a MacBook, keep the Mac usable, and see what the
model is doing. Built around [Slotstream](https://github.com/carloslfu/slotstream) serving
Qwen3.8-Flash-Next on Apple Silicon and [OpenCode](https://opencode.ai) as
the client.

What you get:

- **OpenCode plugin** (`model-stats.ts`): a live toast while the model reads
  your prompt, then a full report: tokens, cache hit rate, time to first
  token, prefill and decode rates, memory plan, and clear failure diagnostics.
- **Server supervision** (`scripts/slotkeeper`): start at login,
  restart after a crash, named context profiles, port-conflict and disk checks,
  log rotation, support bundle, release install with rollback.
- **Menu-bar app** (`Slotkeeper/`, the Swift package): state, memory pressure, expert cache,
  the request in flight with prefill progress, the background tests, and a
  dashboard window with charts.
- **Continuous exerciser** (`scripts/exerciser.py`): a rotating suite of
  realistic and adversarial tasks that measures cost and behaviour around the
  clock, yields to your own requests and to battery, and can be paused from
  the menu bar.
- **Metrics and reports**: 30-second system samples, per-request rows, and a
  one-command summary.
- **Slotstream patches** (`patches/`): make memory-pressure failures
  retryable by OpenCode, and stop a stale OS pressure level from refusing
  requests. Optional; everything else works on stock Slotstream.

Tested on one machine: a 24 GB M4 Pro MacBook, macOS 26, Slotstream 0.2.14,
OpenCode 1.18.30. Expect rough edges elsewhere and read the traps in
`APP_IMPLEMENTATION.md`.

## What you need

- macOS 14 or later on Apple Silicon.
- [Slotstream](https://github.com/carloslfu/slotstream) installed at
  `~/.slotstream/bin/slotstream` with the model pulled (`slotstream pull`).
  Follow its README for that.
- OpenCode.
- `python3` (3.9+), `jq`, Node.js and npm. `brew install jq node` covers the
  missing ones.
- Xcode or the Command Line Tools if you want the menu-bar app (`swift`).

## Quick start

```sh
git clone https://github.com/kewp/slotkeeper ~/slotkeeper
cd ~/slotkeeper
scripts/setup.sh
```

The setup script checks the requirements, asks for a port and a default
profile, installs the plugin, prints the provider block to put in
`~/.config/opencode/opencode.json`, and offers to install the background
services. `scripts/setup.sh --yes` takes the defaults. Restart OpenCode
afterwards and pick the `slotstream` provider.

Everyday commands:

```sh
scripts/slotkeeper status            # process, port, plan, cache, pressure, profile
scripts/slotkeeper restart deep      # 65K window for a long session; 'restart everyday' for 32K
scripts/slotkeeper exerciser status  # background suite; also pause / resume / report
scripts/slotkeeper logs 100
scripts/report.py --hours 24                # your OpenCode sessions first, then the synthetic suite
scripts/exerciser.py --sweep 4000,8000,16000,24000,32000 --label everyday   # TTFT by prompt size
scripts/bench.py --label mytest             # one-off measurement
scripts/pressure-drill.sh                   # simulated memory pressure during a request (needs sudo)
scripts/slotkeeper bundle            # support bundle for bug reports
```

`scripts/slotkeeper` with no arguments lists everything. Put `scripts/` on
your `PATH` or symlink it to use `slotkeeper status` from anywhere:
`ln -s ~/slotkeeper/scripts/slotkeeper /usr/local/bin/slotkeeper`.

## How the pieces fit

```text
OpenCode ──plugin──▶ toasts + log records + ~/.slotstream/opencode-active
   │
   ▼  http://localhost:<port>/v1
Slotstream server  ◀── slotkeeper (launchd, profiles, caffeinate on AC)
   ▲        │
   │        └── /api/ps, /api/show ──▶ monitor.sh (30 s samples) ─┐
   │                                                             ▼
exerciser.py (tasks, yields to OpenCode/battery/pressure) ──▶ ~/.slotstream/metrics/*.jsonl
                                                                 │
Slotkeeper (menu bar + dashboard) ◀───────────────────────────┘
```

Profiles set the context window and are kept in `~/.slotstream/profile`:
everyday 32,768, conservative 16,384, deep 65,536. Every start rewrites the
OpenCode provider's port and `limit.context` to match, so the two cannot
drift. Settings shared by all tools live in `~/.slotstream/ctl.env`.

## Slotstream patches (optional)

Stock Slotstream reports memory-pressure interruptions with wording that
OpenCode's retry loop does not recognise, it trusts the OS pressure level
alone, which can stay elevated after the pressure is gone, and it retains
only a tenth of the pool budget as conversation state, so on a small Mac a
long coding session re-prefills its whole history every turn. Its elastic
cache also regrows straight back to a size that just met memory pressure,
which fails the next long prompt. Four patches against 0.2.14 source fix
that, each with new assertions in Slotstream's own T0 check suite. None is
needed for anything else here.
One command does it, about five minutes with Xcode or the Command Line Tools
installed:

```sh
scripts/slotkeeper patch            # extract shipped source, patch, make checks, build, install, restart
scripts/slotkeeper patch --status   # are the patches in the installed binary?
```

`patches/README.md` has the reasoning, the manual steps, and pull-request text
for upstreaming. If you do not, everything else here still works; you lose
automatic retry after a pressure failure and fast follow-up turns in long
conversations. To keep whole conversations, put
`SLOTSTREAM_PREFIX_CACHE_TOKENS=full` in `~/.slotstream/ctl.env` and restart.

## Documents

| File | What it is |
| --- | --- |
| `APP_PLAN.md` | Where this is going, and why context windows beyond 65K are the wrong lever on a 24 GB Mac |
| `APP_IMPLEMENTATION.md` | Hand-off guide: data formats, code map, staged tasks with verification, known traps |
| `LOCAL_LLM_ROADMAP.md` | Reliability roadmap, review of the plan against the live machine, ideas |
| `SLOTSTREAM_DEVELOPMENT.md` | How Slotstream is built, what is hard to change, how to patch and ship it |
| `SLOTSTREAM_RECOVERY.md` | The author's installed build, validation evidence, rebuild and rollback procedure |
| `CLAUDE.md` | Operating rules for AI assistants working in this repo |

## Notes

- OpenCode's TUI has one toast slot; a later toast can replace the 24-hour
  report. The structured log record stays.
- The OpenAI-compatible stream does not carry prefill progress, so the
  plugin's live count and ETA are estimates. The menu-bar app reads exact
  progress from the server log.
- Ollama also defaults to port 11434. The setup default of 11435 avoids that.
- OpenCode names each session by asking the model for a title, which costs a
  request on the local server. Turn it off with
  `"agent": { "title": { "disable": true } }` in `opencode.json`, or route it
  to a cheap model with `"small_model": "provider/model"`.
- Everything here is MIT licensed. [Slotstream](https://github.com/carloslfu/slotstream)
  and the model have their own licences.
