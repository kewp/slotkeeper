# Slotstream Development Guide

Last updated: 2026-09-11

## Scope

This guide explains how difficult Slotstream is to modify, how to make and ship a
local change safely, what changing context entails, how future model support
would work, and how a native macOS controller could be built.

Slotstream is easy to extend around its edges and difficult to alter in its
inference core. The code is relatively compact and has strong checks, but memory
planning, model geometry, expert streaming, recurrent state, prefix reuse, and
pressure behavior intentionally share strict invariants.

## Difficulty by Area

| Change | Difficulty | Main risk |
| --- | --- | --- |
| CLI option or command | Low | Argument and documentation drift |
| Diagnostic or check | Low | Choosing the correct test tier |
| Read-only metadata endpoint | Low to moderate | Reading mutable engine state unsafely |
| Protocol adapter | Moderate | Streaming and error semantics |
| Sampling option | Moderate | Cross-dialect parity and determinism |
| Memory-planning policy | Moderate to high | Planner, admission, and reporting divergence |
| Pressure or elastic behavior | High | Lock ordering and in-flight cancellation |
| Context ceiling | High | State memory, transient workspace, and qualification |
| Prefix-cache behavior | High | Recurrent state cannot be arbitrarily rewound |
| Checkpoint variant | High to very high | Tensor names, packing, and geometry assumptions |
| New model architecture | Very high | Loader, layers, state, planner, and parity all change |

Our retry wording and server logging changes are edge changes. They touched
request control, HTTP error reporting, and diagnostics without changing tensor
execution. That is why they were practical to implement and validate locally.

## Source Architecture

The Swift package defines:

- `Slotstream`: production library
- `SlotstreamDiagnostics`: reusable checks and benchmark support
- `slotstream`: command-line executable
- `slotstream-checks`: custom test runner

The main runtime path is:

```text
CLI ModelOptions
  -> Planner and MemoryPlan
  -> Engine
       -> CheckpointIndex
       -> Qwen4ExpModel
            -> resident trunk weights
            -> SSD-backed ExpertStore and SlotPool
            -> NgramStore
            -> optional MTPHead and VisionTower
       -> Generator
       -> PrefixCache
       -> RequestController
  -> Server
```

Important files in a Slotstream source tree:

| File | Responsibility |
| --- | --- |
| `Package.swift` | Products, targets, dependencies, macOS floor |
| `Sources/slotstream-cli/main.swift` | CLI options, planning, startup, doctor |
| `Sources/Slotstream/Engine.swift` | Model lifecycle, request gate, generation, prefix reuse |
| `Sources/Slotstream/Server.swift` | HTTP routing and streaming dialects |
| `Sources/Slotstream/RequestControl.swift` | Deadlines, disconnects, pressure, reservations |
| `Sources/Slotstream/Plan.swift` | Startup memory and cache planning |
| `Sources/Slotstream/Context.swift` | Context policy and prefill schedule |
| `Sources/Slotstream/ContextMemory.swift` | Context and workspace memory accounting |
| `Sources/Slotstream/Governor.swift` | Elastic cache growth and shrink |
| `Sources/Slotstream/Checkpoint.swift` | Config parsing and exact model validation |
| `Sources/Slotstream/Model.swift` | Architecture assembly |
| `Sources/Slotstream/PrefixCache.swift` | Conversation-state retention and accounting |
| `Sources/Slotstream/WeightStore.swift` | Model presence, validation, and download state |
| `Sources/Slotstream/PinnedModel.swift` | Exact supported model manifest |

## Request Lifecycle

A normal inference request:

1. Reads a bounded HTTP body and validates the dialect.
2. Creates a `RequestController` before expensive tokenization.
3. Attaches deadline, connection, memory-pressure, and allocation guards.
4. Renders and tokenizes the conversation.
5. Acquires the single-flight generation gate.
6. Rechecks context and pressure after waiting in the queue.
7. Clamps output to the remaining shared context window.
8. Reuses an exact prefix when possible.
9. Runs prefill and decode while continuing to check cancellation and pressure.
10. Streams output through a bounded queue, publishes statistics, and releases
    reservations.

Preserve this path when adding a protocol or UI. Bypassing `Engine` admission or
calling model internals directly can skip memory and cancellation guarantees.

## How to Make a Local Change

### 1. Start from identifiable source

Use an exact upstream release or a matching `build-source.tar.gz`. Determine
whether that source is stock or already patched before doing anything. Do not
edit only the installed executable's temporary build tree and assume it is
durable.

For this installation, the stock 0.2.14 archive was preserved as:

```text
~/.slotstream/bin/build-source.tar.gz.0.2.14.original
```

The currently installed `build-source.tar.gz` contains the source used for the
installed binary. It is already patched and must not receive the same patch a
second time. Because `~/.slotstream/bin` is a release symlink, preserve important
source and patches in a separate repository before upgrading.

### 2. Keep the durable change as a patch

The current integration patch is:

```text
patches/slotstream-0.2.14-opencode-retry.patch
```

For stock 0.2.14 source, check the actual target directory and fail closed if the
patch is already present or cannot apply forward:

```sh
patch --dry-run --forward --batch -p1 < patches/slotstream-0.2.14-opencode-retry.patch
```

Then apply it once to that same worktree:

```sh
patch --forward --batch -p1 < patches/slotstream-0.2.14-opencode-retry.patch
```

If the source came from the currently installed patched archive, skip both patch
commands. Build it directly or compare it to the durable patch first. Never
accept `patch` prompts offering to reverse a previously applied change.

When updating Slotstream, do not blindly force an old patch through conflicts.
Read the new request, error, and server behavior, recreate the smallest necessary
change, and rerun the complete qualification path.

### 3. Add checks at the lowest useful tier

The project uses a custom check catalogue:

- T0: pure Swift
- T1: MLX kernels without model weights
- T2: tokenizer fixture
- T3: synthetic checkpoint
- T4: real model weights

Policy and error-contract changes should usually have T0 coverage. Tensor,
checkpoint, throughput, or long-context changes need higher tiers and often a
real-model acceptance run.

### 4. Build and validate

```sh
make checks
make build
```

Useful broader targets in a complete upstream checkout include `make checks-all`,
`make test`, and `make context-test`. The reconstructible build-source archive
omits `Tools/verify.sh` and `Tools/context_acceptance.py`, so the last two targets
are unavailable from that archive alone. A release executable that uses MLX must
have the matching `mlx.metallib` beside it.

Do not treat successful compilation as sufficient for memory, context, cache, or
model-layout changes. Validate the affected policy checks, deterministic parity,
real weights, and a representative end-to-end request.

### 5. Install the complete release unit

Keep these artifacts together:

```text
slotstream
mlx.metallib
build-identity.json
build-source.tar.gz
```

Preserve the previous complete release, install matching artifacts atomically,
restart the service, compare hashes, check `/api/version`, and run one inference.
The detailed procedure and current hashes are in `SLOTSTREAM_RECOVERY.md`.

## Changing Context

### Supported change today

The CLI already accepts:

```sh
slotstream serve --max-context N
```

Stock serving accepts values from 1 through 65,536. The ordinary default is
32,768. Prompt and reply share that window.

Changing from the current 65,536 to 32,768 does not require a custom build. It
requires restarting Slotstream with the new argument and changing OpenCode's
provider context declaration to match.

### Why 65K costs more

`ContextPolicy.tokensInFixedFootprint` is 32,768. Above it, the planner charges:

- Additional active sequence state
- A conservative long-context transient reserve

For this model, sequence state is based on 12 attention layers and 2,304 bytes
per token row. Prefix state is charged at 27,648 bytes per retained token. Moving
from 32K to 65K adds roughly 0.9 GB in active state plus a roughly 0.9 GB reserve,
matching the approximately 1.8 GB startup-plan difference.

### Increasing above 65K

The checkpoint declares a 262,144-token model limit, but Slotstream's released
implementation is qualified only to 65,536. Raising one constant is not enough.
A safe higher limit requires synchronized work in:

- `ContextPolicy` validation and public CLI help
- Planner feasibility and cache-size tradeoffs
- Sequence-cache allocation and replacement reserves
- Prefill query-by-key workspace bounds and late-context chunking
- Request admission, deadlines, and output clamping
- Prefix-retention limits
- MTP and vision qualification
- API metadata and diagnostics
- Synthetic context tests and real long-context acceptance

Approximate sequence-state and reserve costs grow with the additional tokens.
At 131K, the extra active state and conservative reserve together are roughly
5.4 GB beyond the 32K fixed footprint, before considering useful expert-cache
capacity. On a 26 GB Mac this is likely to reduce speed and coexistence enough to
defeat the continuous-service goal.

The better near-term direction is a 32K everyday profile and explicit 65K deep
sessions. Only qualify a larger ceiling after collecting a concrete workload
that cannot be solved by session compaction or summarization.

## Memory and Pressure Changes

Memory changes are harder than API changes because startup planning, live request
admission, elastic resizing, and status reporting share the same accounting.

Rules for changing them:

- Keep memory decisions in `MemoryPlan` and `ContextMemoryLedger`.
- Keep auto plans elastic; explicit cache sizes are intentionally pinned.
- Resize only while owning the generation gate.
- Preserve lock ordering between the governor, engine, prefix cache, and pool.
- Publish immutable status snapshots rather than exposing mutable pool state to
  HTTP handlers.
- Test warning and critical pressure, queue waits, cancellation, resize
  hysteresis, retained-prefix invalidation, and recovery output parity.

A useful next change would expose the governor's current state and resize history
as structured metadata. A riskier later change would add proactive shrink based
on an availability trend rather than waiting for OS pressure.

## Supporting Future LLMs

Slotstream is currently specialized for one Qwen3.8-Flash-Next 4-bit geometry. It
validates exact hidden size, layer count, attention layout, 512 experts, top-10
routing, expert shape, recurrent/QSA arrangement, quantization, PLE, and
hyper-connections. The planner also knows the exact expert-record size before
the model is loaded.

Supporting another architecture is therefore a substantial port, not a manifest
edit.

### First additional model

For the first new model, avoid designing a universal abstraction in advance.

1. Inventory its config, tensor names, quantization, layer layout, state types,
   context behavior, tokenizer, chat template, and optional vision/draft heads.
2. Decide which weights remain resident and which can stream from SSD.
3. Build a checkpoint adapter with exact tensor-shape validation.
4. Implement its layers and generation state without weakening existing checks.
5. Add a model-specific planner geometry and measured cost profile.
6. Define prefix-cache identity and whether its state can be safely forked,
   extended, or rolled back.
7. Add reference parity fixtures, synthetic checkpoints, and real-weight golden
   tests.
8. Expose only capabilities the implementation actually qualifies.

### Generalize after two working backends

Once two architectures work, extract only demonstrated common seams, likely:

- Model descriptor and capabilities
- Checkpoint locator and validator
- Planner geometry and measured cost profile
- Tokenizer/chat renderer
- Generation backend and state lifecycle
- Prefix-cache policy
- Optional vision and speculative-decoding capabilities

The server, request admission, cancellation, and protocol dialects can remain
shared. Model execution, cache semantics, and planner geometry should remain
backend-specific where their invariants differ.

### Qualification standard

A future model should not be called supported until it has:

- Exact checkpoint and tokenizer identity
- Deterministic short-prompt parity against a trusted reference
- Multi-turn prefix-reuse parity
- Cancellation and retry recovery checks
- Context and output boundary tests
- Memory-plan measurements on the target Mac class
- Pressure behavior and repeated start/stop tests
- Tool-call and streaming protocol checks when advertised
- A pinned source, dependency, metallib, and model manifest release unit

## Native macOS App

### Would it be useful?

Yes, if it solves lifecycle and reliability rather than merely placing Start and
Stop in a menu. The useful product is a local-model controller with:

- Clear loading, ready, busy, pressure, and failed states
- Memory and context profiles
- Start at login and sleep/wake handling
- Crash supervision with bounded backoff
- Model download, resume, verification, and disk-space status
- Current plan, expert residency, prefix cache, and recent request metrics
- Logs and actionable recovery messages
- Safe updates of the app, helper, metallib, and compatibility metadata

### Recommended architecture

Do not load the model in the menu-bar UI process. `Engine` owns a very large MLX
workload, process-wide allocator settings, pressure monitoring, a model lock, and
synchronous single-flight generation. A failure should not take down the UI.

Use two processes:

```text
SwiftUI/AppKit menu-bar app
  -> supervises and queries
signed Slotstream helper process
  -> owns Engine, Server, MLX, weights, and localhost API
```

For an MVP, supervise an exact bundled `slotstream` executable and use the
existing HTTP metadata endpoints. Parse startup logs only where no structured
status exists.

For a production version, build an app-owned helper that imports the Slotstream
Swift package and exposes typed XPC or local Unix-socket management events. Keep
inference in that helper process.

### Existing useful surfaces

- `doctor --json` for preflight planning
- `WeightStore` for ready, missing, incomplete, and corrupt model states
- `/api/version` for version
- `/api/ps` for loaded process/model state
- `POST /api/show` with a valid model body for plan and cache metadata
- OpenAI- and Ollama-compatible inference endpoints

### Missing control-plane APIs

- Loading progress and readiness state
- Graceful drain and shutdown
- Busy state, queue depth, and active request ID
- Out-of-band request cancellation
- Structured governor state and resize events
- Structured model-download progress
- Runtime profile changes and safe cache controls
- Error history and process-instance identity

These are valuable Slotstream contributions even if the app is never built.

### Staged effort

| Stage | Scope | Rough effort |
| --- | --- | ---: |
| Prototype | Menu icon, launch/terminate, health, basic status | 4 to 7 days |
| Personal MVP | Profiles, logs, doctor, crash handling, login item | 2 to 4 weeks |
| Bundled signed helper | Exact helper/metallib packaging and notarization | 1 to 2 weeks |
| Typed control plane | Lifecycle, progress, busy state, cancellation IPC | 3 to 5 weeks |
| Production hardening | Updates, migration, QA, accessibility, support bundle | 4 to 8 weeks |

The first prototype should not include a chat UI. OpenCode already supplies the
client experience; the app's unique value is keeping inference healthy.

### Distribution concerns

- Pin Slotstream rather than tracking its development head.
- Sign and notarize the nested helper and app with Hardened Runtime.
- Package the matching `mlx.metallib` correctly.
- Preserve the model outside the app bundle across updates.
- Start with Developer ID distribution outside the Mac App Store; sandboxing a
  loopback server, external model storage, and low-level file access adds work.
- Preserve Slotstream and dependency notices.
- Review the pinned model's own license before commercial distribution,
  especially for an AI work-assistant product.

## Recommended Sequence

1. Run the 32K continuous-profile experiment.
2. Make plugin installation independent of the repository.
3. Add LaunchAgent or supervisor lifecycle and log rotation.
4. Add structured lifecycle, busy, governor, and error status to Slotstream.
5. Build a small menu-bar prototype around the supervised executable.
6. Decide whether its daily value justifies the signed-helper and model-management
   work.
7. Attempt a second model backend only when there is a specific model and a clear
   performance or capability reason.

This sequence improves daily reliability at every step without committing early
to the riskiest inference-core or native-distribution work.
