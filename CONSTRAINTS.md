# Every limit between us and the machine's real capability

The rule this file exists to enforce: **no failure is ever reported as "the machine
cannot" until it has been traced to an entry here.** Each entry is one of three things.

- **searched** — calibration varies it automatically; it can never silently cap capability.
- **patched** — it used to be fixed, we changed Slotstream, and now it is searched or gone.
- **physics** — it follows from the hardware or the checkpoint, and the only answer is
  different hardware or a different model. These are the only acceptable "cannot"s.

If a new failure does not map to a row below, the row is missing: add it, then decide
which of the three it is. "That is how Slotstream does it" is not one of the three.

## Searched

| Limit | Where | How it is searched |
| --- | --- | --- |
| Total memory target | `SLOTSTREAM_MEMORY_GB` → `--memory-gb` | From 95% of RAM downward until one serves a prompt without a memory failure or critical pressure. Overrides auto's 33 GB model ceiling and is deliberately not capped by the Metal working set: the server's refusal is the measurement, not our guess. |
| Context window | profile / `--max-context` | 262,144 downward; the largest that carries prompts to three quarters of itself wins. |
| Retention | `SLOTSTREAM_PREFIX_CACHE_TOKENS` | Whole conversation, then 32,768, then the server's default. A window that will not start with everything kept usually starts with less. |
| Prefill chunk | `SLOTSTREAM_PREFILL_CHUNK` | Default, then 512, then 256. A smaller pass needs far less transient memory, which is what a long prompt runs out of. |
| Prefill-wait budget | `slotkeeper` `prefill_wait_for` | Scales with the window: twice the estimated full-window prefill. A fixed ten minutes silently capped prompts at about 24K. |
| Expert cache size | the planner, from the target | Follows the memory target; the governor resizes it live. |
| Longest test prompt | `EXERCISER_MAX_PROMPT`, `--sweep auto` | Derived from the server's window, not a constant. |

## Patched

| Limit | Was | Now |
| --- | --- | --- |
| Qualified window ceiling | `ContextPolicy.implementationLimit` refused anything above 65,536 | `serve --beyond-qualified-context` admits up to the checkpoint's 262,144; the planner still refuses a window that does not fit, so memory decides (patch six) |
| Retention dropped on any shrink | the governor dropped held conversations whenever the pool shrank, and always at the floor | kept unless pressure is critical (patch five) |
| Refusal instead of degradation | an infeasible replan refused every request | sheds the held conversation and keeps serving (patch five) |
| Lost prefill on a refusal | a refused request discarded everything it had read | keeps the committed prefix, so the retry resumes (patch five) |
| Retry wording | pre-output pressure failures were not retryable by clients | advertised as retryable when a replay is safe (patch one) |
| Stale pressure latch | an elevated kernel level refused every request indefinitely | cross-checked against reclaimable memory (patch two) |
| Regrowth after pressure | the pool grew straight back into the size that had just failed | capped below it for 20 minutes (patch three) |

## Physics

| Limit | Why it is real |
| --- | --- |
| 68 GB of experts on a 24 GB machine | Most of each token is streamed from SSD. Generation sits near 3 tok/s here and rises with memory because more experts stay cached. Different hardware is the only lever. |
| 27,648 bytes per context token | The model's own state size. It sets what a window costs: about 0.11 GB per 1,000 tokens with the whole conversation kept. |
| 262,144-token checkpoint limit | The positions the checkpoint was configured for. Beyond it is a different model, not a setting. |
| Prefill roughly linear in tokens, slower at long positions | Attention over a growing context. Measured 89 tok/s at 19K falling to 33 tok/s at 54K on this machine. |

## Still to decide

| Limit | Status |
| --- | --- |
| Minimum expert pool (`Geometry.floorSlots`, 640 slots, 1.77 GB) | A floor tied to the prefill chunk: below it one pass can pin every slot. With a 256-token chunk it could be lower, which would free memory for the window. Candidate for patch eight; not yet measured. |
| Per-pass admission refusal | A long prompt is refused when one pass does not fit, rather than the pass being made smaller. Patch seven: fall back to a smaller chunk in place, instead of failing the request. |
| Availability slack (`max(1.5 GB, 5% of RAM)`) and the 1 GB planning margin | Real guards against the machine becoming unusable. Worth measuring whether they can be smaller on a large machine; not a capability cap today. |
| Metal working set (`device_working_set_gb`, about 75% of RAM) | The planner bounds a plan's peak by it. macOS reports it as a recommendation, not a hard wall, so a target above it is worth measuring rather than assuming; the search now tries targets above it and records what the server says. |
| What else is running | A target that fails while a browser holds memory can succeed on a quiet machine: 17.3 GB was refused at 10:47 and started at 11:06. The verdict records the machine's state, and calibration prefers to run when you are away. |
