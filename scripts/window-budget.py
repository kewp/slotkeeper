#!/usr/bin/env python3
"""How large a context window fits in a given amount of memory, and what it costs.

The planner's own ledger, verified against a running server on 2026-09-12, is:

  target  >=  fixed footprint 5.30 GB
            + planning margin 1.00 GB
            + 3 x 27,648 bytes per token of window above 32,768   (active state + reserve)
            + prefill workspace (0.33 / 0.66 / 1.33 GB at chunk 256 / 512 / 1024)
            + 27,648 bytes per retained token + 0.34 GB of fixed retention overhead
            + expert pool (0.133 GB per expert per layer, floor 1.77 GB = 13/layer)

Everything context-shaped costs the same 27,648 bytes per token, which is why the
window is expensive: with a full conversation retained, each 1,000 tokens of window
costs about 0.11 GB, and you pay it whether or not a request uses the whole window.

Usage:
  window-budget.py --capacity           what this machine has actually handled, with the reason
  window-budget.py                      read this machine and report
  window-budget.py --ram 64             plan for a machine with 64 GB
  window-budget.py --window 49152       what that window costs here
  window-budget.py --ram 64 --experts 100   with an explicit expert cache size

The answer is a ceiling, not a promise: a long prefill also has to fit in whatever
memory is free at the moment it runs, and other applications decide that. Leave
headroom, and see LOCAL_LLM_ROADMAP.md for what happened when we did not.
"""
import argparse, json, os, subprocess, sys

BYTES_PER_TOKEN = 27_648          # KV + indexer state, per token, everywhere it appears
FIXED_GB = 5.30                   # resident weights, n-gram payload, runtime
MARGIN_GB = 1.00                  # planner's margin
RETENTION_OVERHEAD_GB = 0.34      # fixed recurrent state for the spare retained entries
POOL_FLOOR_GB = 1.77              # 640 slots, ~13 experts/layer
GB_PER_EXPERT_PER_LAYER = 0.1327  # 48 layers x 2.76 MB
FREE_CONTEXT = 32_768             # the fixed footprint already pays for this much window
PREFILL_GB = {256: 0.33, 512: 0.66, 1024: 1.33, 2048: 2.66, 4096: 5.32}
MODEL_CEILING_GB = 33.0           # auto's ceiling for this model, whatever the machine has
SERVER_WINDOW_LIMIT = 65_536      # Slotstream's implementation limit


def gb(tokens):
    return tokens * BYTES_PER_TOKEN / 1e9


def machine():
    """This Mac's RAM and Metal working set, or None when they cannot be read."""
    try:
        ram = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True,
                                 timeout=5).stdout.strip()) / 1e9
    except (OSError, ValueError, subprocess.SubprocessError):
        return None, None
    return ram, ram * 0.75  # the working set macOS grants Metal is about three quarters


def target_gb(ram, working_set, percent):
    """What auto will aim for: a share of RAM, bounded by the working set and the model."""
    return min(MODEL_CEILING_GB, percent / 100 * ram, working_set - 2.0)


def peak_gb(window, pool_gb, retained_tokens, chunk):
    return (FIXED_GB + 3 * gb(max(0, window - FREE_CONTEXT)) + PREFILL_GB.get(chunk, 1.33)
            + gb(retained_tokens) + (RETENTION_OVERHEAD_GB if retained_tokens else 0) + pool_gb)


def largest_window(target, pool_gb, chunk, retain_full):
    """The biggest window whose plan still fits, retaining the whole window or nothing."""
    room = target - MARGIN_GB - FIXED_GB - PREFILL_GB.get(chunk, 1.33) - pool_gb
    if retain_full:
        room -= RETENTION_OVERHEAD_GB
        # room = 3u(W - 32768) + uW  ->  W = (room/u + 3*32768) / 4
        window = (room / gb(1) + 3 * FREE_CONTEXT) / 4 if room > 0 else 0
    else:
        window = room / gb(1) / 3 + FREE_CONTEXT if room > 0 else 0
    return int(max(0, min(window, SERVER_WINDOW_LIMIT)))


STANDARD_WINDOWS = [16_384, 32_768, 49_152, 65_536]


def measured(home):
    """What this machine has actually done: prompt sizes that worked, and that did not.

    Joins the exerciser's rows with the monitor's samples, which is where the window in
    force at the time is recorded, and adds your own OpenCode turns from its database."""
    import glob
    from datetime import datetime

    def when(row):
        try:
            return datetime.fromisoformat(row["ts"].replace("Z", "+00:00")).timestamp()
        except (KeyError, ValueError, AttributeError):
            return None

    windows = []
    for f in sorted(glob.glob(os.path.join(home, "metrics", "20*.jsonl"))):
        for line in open(f, errors="replace"):
            try:
                row = json.loads(line)
            except ValueError:
                continue
            w, t = (row.get("slotstream") or {}).get("max_context"), when(row)
            if w and t:
                windows.append((t, w))
    windows.sort()

    def window_at(t):
        best = None
        for sample_t, w in windows:
            if sample_t <= t + 60:
                best = w
            else:
                break
        return best

    worked, failed = {}, {}
    path = os.path.join(home, "metrics", "exerciser.jsonl")
    if os.path.exists(path):
        for line in open(path, errors="replace"):
            try:
                row = json.loads(line)
            except ValueError:
                continue
            t = when(row)
            if not t:
                continue
            w = window_at(t)
            if not w:
                continue
            code = ((row.get("error") or {}).get("code") if isinstance(row.get("error"), dict) else None)
            if row.get("ok") and row.get("prompt_tokens"):
                worked[w] = max(worked.get(w, 0), row["prompt_tokens"])
            elif code == "insufficient_memory":
                # The prompt it could not read: what the task aimed for, not what it read.
                size = (row.get("details") or {}).get("est_prompt_tokens") or row.get("prompt_tokens")
                if size:
                    failed[w] = min(failed.get(w, 10 ** 9), size)
    return worked, failed


def own_turns(home):
    """The largest prompt your own OpenCode sessions have had answered."""
    db = os.environ.get("OPENCODE_DB", os.path.expanduser("~/.local/share/opencode/opencode.db"))
    if not os.path.exists(db):
        return None
    import sqlite3
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
        row = con.execute(
            """select max(json_extract(data,'$.tokens.input') + json_extract(data,'$.tokens.cache.read'))
                 from message
                where json_extract(data,'$.providerID') = ?
                  and json_extract(data,'$.role') = 'assistant'
                  and json_extract(data,'$.error') is null
                  and json_extract(data,'$.time.completed') is not null""",
            (os.environ.get("SLOTSTREAM_PROVIDER_ID", "slotstream"),)).fetchone()
    except sqlite3.Error:
        return None
    return row[0] if row and row[0] else None


def capacity(ram, working_set, percent, pool, chunk, home):
    worked, failed = measured(home)
    mine = own_turns(home)
    target = target_gb(ram, working_set, percent)
    ceiling = largest_window(target, pool, chunk, True)
    best_prompt = max(list(worked.values()) + ([mine] if mine else []) or [0])
    first_failure = min(failed.values()) if failed else None

    # A window is only recommended when the plan fits with the whole conversation
    # retained, and nothing this size has failed for memory in the record.
    recommended = 0
    for w in STANDARD_WINDOWS:
        if peak_gb(w, pool, w, chunk) + MARGIN_GB > target:
            break
        if first_failure and first_failure <= w * 0.75:
            break
        recommended = w
    comfortable = min(best_prompt, int(recommended * 0.75)) if recommended else best_prompt
    if first_failure:
        comfortable = min(comfortable, int(first_failure * 0.8))
    return {
        "ram_gb": round(ram, 1), "target_gb": round(target, 2), "pool_gb": round(pool, 2),
        "plan_ceiling_tokens": ceiling,
        "recommended_window": recommended,
        "comfortable_prompt_tokens": int(comfortable // 1000 * 1000),
        "largest_prompt_answered": best_prompt or None,
        "largest_own_session_prompt": mine,
        "first_memory_failure_at": first_failure,
        "evidence_by_window": {str(w): {"largest_ok": worked.get(w), "first_memory_failure": failed.get(w)}
                               for w in sorted(set(list(worked) + list(failed)))},
        "limit": ("the plan does not fit above this window" if recommended and
                  peak_gb(min(STANDARD_WINDOWS[-1], recommended * 2), pool, recommended * 2, chunk) + MARGIN_GB > target
                  else "long prefills ran out of memory above this size in testing"),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ram", type=float, help="machine RAM in GB (default: this machine)")
    ap.add_argument("--percent", type=float, default=70, help="RAM share auto may target (default 70)")
    ap.add_argument("--experts", type=int, help="experts per layer to keep cached (default: the floor)")
    ap.add_argument("--chunk", type=int, default=1024, help="prefill chunk (default 1024)")
    ap.add_argument("--window", type=int, help="price this window instead of solving for the largest")
    ap.add_argument("--capacity", action="store_true",
                    help="what this machine has actually handled, from the recorded tests")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    ram, working_set = (a.ram, a.ram * 0.75) if a.ram else machine()
    if not ram:
        sys.exit("could not read this machine's memory; pass --ram")
    pool = a.experts * GB_PER_EXPERT_PER_LAYER if a.experts else POOL_FLOOR_GB
    target = target_gb(ram, working_set, a.percent)

    if a.capacity:
        home = os.environ.get("SLOTSTREAM_HOME", os.path.expanduser("~/.slotstream"))
        report = capacity(ram, working_set, a.percent, pool, a.chunk, home)
        if a.json:
            print(json.dumps(report, indent=2))
            return
        print(f"about {report['comfortable_prompt_tokens']:,} tokens of prompt is what this machine handles")
        print(f"  recommended window: {report['recommended_window']:,} tokens "
              f"(the plan fits up to {report['plan_ceiling_tokens']:,} at a {report['target_gb']:.1f} GB target)")
        if report["largest_prompt_answered"]:
            print(f"  largest prompt answered here: {report['largest_prompt_answered']:,} tokens")
        if report["first_memory_failure_at"]:
            print(f"  first memory failure seen at: {report['first_memory_failure_at']:,} tokens")
        print(f"  limiting factor: {report['limit']}")
        return

    if a.window:
        full = peak_gb(a.window, pool, a.window, a.chunk)
        none = peak_gb(a.window, pool, 0, a.chunk)
        report = {"ram_gb": round(ram, 1), "target_gb": round(target, 2), "window": a.window,
                  "pool_gb": round(pool, 2), "peak_full_retention_gb": round(full, 2),
                  "peak_no_retention_gb": round(none, 2),
                  "fits_with_retention": full + MARGIN_GB <= target,
                  "fits_without_retention": none + MARGIN_GB <= target}
    else:
        report = {"ram_gb": round(ram, 1), "percent": a.percent, "target_gb": round(target, 2),
                  "pool_gb": round(pool, 2),
                  "largest_window_full_retention": largest_window(target, pool, a.chunk, True),
                  "largest_window_no_retention": largest_window(target, pool, a.chunk, False)}

    if a.json:
        print(json.dumps(report, indent=2))
        return
    print(f"machine: {report['ram_gb']:.0f} GB RAM, auto targets {report['target_gb']:.1f} GB "
          f"at {a.percent:.0f}% (bounded by the model's {MODEL_CEILING_GB:.0f} GB ceiling and the Metal working set)")
    print(f"expert cache: {report['pool_gb']:.2f} GB"
          + (f" ({a.experts}/layer)" if a.experts else " (the floor, ~13/layer)")
          + f", prefill chunk {a.chunk}")
    if a.window:
        for label, key in (("with the whole window retained", "peak_full_retention_gb"),
                           ("with retention off", "peak_no_retention_gb")):
            fits = report["fits_with_retention"] if "full" in key else report["fits_without_retention"]
            print(f"  window {a.window:,}: peak {report[key]:.2f} GB {label} — "
                  + ("fits" if fits else f"does NOT fit in {report['target_gb']:.1f} GB"))
    else:
        print(f"  largest window with the whole conversation retained: {report['largest_window_full_retention']:,} tokens")
        print(f"  largest window with retention off:                   {report['largest_window_no_retention']:,} tokens")
        print(f"  (Slotstream refuses anything above {SERVER_WINDOW_LIMIT:,} whatever the memory)")
    print("\nA long prefill also has to fit in memory that is free at that moment, which your other")
    print("apps decide, so treat this as a ceiling and leave headroom.")


if __name__ == "__main__":
    main()
