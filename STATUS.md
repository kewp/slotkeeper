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

What it is not: a replacement for a 100K-context cloud agent. The window stops at
65,536 (Slotstream refuses more), and on 24 GB the practical ceiling is lower still.
Generation runs at about 3 tokens per second because the model streams 68 GB of experts
from SSD; no amount of tuning changes that on this hardware.

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
6. **A fresh machine still needs a person.** `setup.sh` installs and starts services but
   does not yet calibrate, so a new user gets defaults rather than their own numbers.

## The honest limits, with numbers

From the planner's ledger at a 49,152 window: fixed footprint 5.30 GB, planning margin
1.00, context state above 32K 0.45, long-context transient reserve 0.91, prefill
workspace 1.33, retained conversation 1.70, expert pool 3.48, expected peak 13.17.

Every context token costs 27,648 bytes wherever it appears, so with the whole
conversation retained each 1,000 tokens of window costs about 0.11 GB on top of a
9.7 GB base. That is why 65,536 does not fit on this machine under a 55% cap: the
smallest possible plan is 14.27 GB against a 14.2 GB target.

On other machines, with the default 70% share:

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

1. Fall back to a smaller prefill chunk when a pass does not fit, so a long prompt
   degrades instead of failing (the last known reliability gap).
2. Run one real job end to end and fix what that exposes.
3. Score quality on a fixed task set, so "useful" stops being an assumption.
4. Have `setup.sh` finish by calibrating, so a new machine reports its own numbers
   without being asked.
5. Upstream the patches.
