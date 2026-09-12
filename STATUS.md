# Where this project stands

One goal: **automatically work out what this model can do on the Mac it is running on,
and say so.** Not "on this machine, after tuning": on any machine, by itself. Limits in
Slotstream are work items, and constants we picked earlier are superseded by what
calibration measures. Everything below is measured on a 24 GB
M4 Pro unless it says otherwise. Last audit: 2026-09-12.

## The answer so far

A local coding agent at about 25,000 tokens of context is real and usable today. A
session on 2026-09-12 ran 25 turns against a real project: prompts grew from 19K to 32K
tokens, the server reused 98 to 99% of each prompt, and follow-up turns answered in 26
to 80 seconds. The first turn cost 13 minutes, because a cold conversation is read from
scratch.

Generation runs at about 3 tokens per second on this machine because the model streams
68 GB of experts from SSD past a 24 GB memory budget. That ratio is the one thing here
that hardware decides: a machine with more memory caches more experts and goes faster,
which is exactly what calibration reports per machine.

## What is done

| Area | State |
| --- | --- |
| Supervision | Server, monitor, exerciser, job runner and app all run under launchd, survive reboot, restart after a crash |
| Measurement | Per-request rows, 30-second system samples, sweeps, and a report that leads with your own OpenCode sessions |
| Visibility | The app shows the live request, your turns with per-turn reuse, jobs, capacity, the installed build and a health page |
| Capacity | `slotkeeper capacity` prices any window from the planner's ledger, within 0.03 GB of the running server; `slotkeeper calibrate` measures the real answer and keeps it current on its own |
| Reliability patches | Five, all installed and checked: retry wording, prefix retention, pressure ceiling, resume-after-refusal (with the keep-through-warning and shed-instead-of-refuse halves), stale pressure |
| Unattended work | `slotkeeper jobs` queues tasks and runs them overnight, yielding to you, battery, pressure and the night window |
| Portability | Test sizes derive from the server's window, the report's bands scale, `selftest.sh` verifies a checkout without the model, README says what is per-machine |

## What is not done

1. **Quality is unmeasured.** Every number here is speed or reliability. Whether the
   model's output is worth keeping has never been scored. This decides whether the rest
   matters.
2. **The job runner has never completed a real job.** The queue, the yield rules and the
   report are written and exercised; no task has run end to end.
3. **Long prompts still fail at the prefill-pass wall**, which breaks the "degrade,
   never refuse" rule. At a 49,152 window with 26 experts per layer, prompts of 36K and
   up are refused for memory while the machine reports normal pressure. Retries resume
   rather than restart, but ratchet to about 30K and stall. The fix is to fall back to a
   smaller prefill chunk instead of refusing: patch seven.
4. **Windows above 65,536 are now allowed** (`--beyond-qualified-context`, patch six).
   The planner prices any window and refuses one that does not fit, so the machine
   decides. What is still missing is a measurement above 65,536 on a machine with the
   memory for it.
5. **The five patches are not upstreamed.** Pull-request text is written in
   `patches/README.md`.
6. **The search has not yet completed a full run.** Calibration now searches memory
   target and window, including above 65,536, and `setup.sh` installs it on a fresh
   machine; one clean end-to-end run on this Mac is what proves it.

## Where the memory actually goes

A machine reporting "13 GB free" is not idle. On 2026-09-12, with the server running,
`vm_stat` showed 19.3 GB file-backed, 1.6 GB anonymous and 0.2 GB free: the file-backed
pages are the memory-mapped weights, which macOS counts as reclaimable and Activity
Monitor-style tools show as free. The machine is full, and what fills it is the cache
that keeps the next token off the SSD.

So a bigger memory target is a trade, not a free win: it moves RAM from weight cache to
the expert pool and context state. That is the likeliest reason decode has barely moved
across pool sizes here, and it is the thing to measure next rather than assume.

## The honest limits, with numbers

From the planner's ledger at a 49,152 window: fixed footprint 5.30 GB, planning margin
1.00, context state above 32K 0.45, long-context transient reserve 0.91, prefill
workspace 1.33, retained conversation 1.70, expert pool 3.48, expected peak 13.17.

Every context token costs 27,648 bytes wherever it appears, so with the whole
conversation retained each 1,000 tokens of window costs about 0.11 GB on top of a
9.7 GB base. A 55% cap was an early workaround on this machine, and under it 65,536 could not fit:
the smallest possible plan was 14.27 GB against a 14.2 GB target. Calibration no longer
takes that cap as given; it searches the memory target itself and writes what works.

What the arithmetic says for other machines, at the default 70% share (calibration
measures the real answer, which is usually better than this table, because it will take
an explicit memory target past auto's own ceiling):

| RAM | memory target | largest window | expert cache there |
| ---: | ---: | ---: | ---: |
| 16 GB | 8.8 GB | does not fit | – |
| 24 GB | 13.2 GB | ~55,000 | 13/layer |
| 32 GB | 17.6 GB | 65,536 | 38/layer |
| 64 GB | 33.0 GB | 65,536 | 154/layer |
| 128 GB | 33.0 GB | 65,536 | 154/layer |

Above 32 GB the window stops being the constraint and the expert cache grows instead,
which is where speed comes from. The 33 GB ceiling is auto's own limit for this model,
based on Slotstream's measurements of diminishing returns, not a safety margin: the
actual safety margin is the 1 GB planning margin plus an availability slack of
`max(1.5 GB, 5% of RAM)`.

## Next, in order

1. Let the calibration search finish a full run here, and fix what it exposes.
2. Fall back to a smaller prefill chunk when a pass does not fit, so a long prompt
   degrades instead of failing (patch seven).
3. Run one real job end to end and fix what that exposes.
4. Score quality on a fixed task set, so "useful" stops being an assumption.
5. Upstream the patches.
