#!/usr/bin/env python3
"""Summarize what the exerciser, benchmark and monitor have recorded.

Usage: report.py [--hours N] [--json]     (default: last 24 hours)

Reads ~/.slotstream/metrics/{exerciser.jsonl,bench.jsonl,YYYY-MM-DD.jsonl} and prints:
  - pass/fail per task with median TTFT, prefill and decode rates
  - failures and their notes
  - decode rate versus expert-cache size (does more cache actually help?)
  - pressure minutes, cache resize events, battery time, disk floor
  - server process CPU/RSS peaks during tasks
"""
import argparse, glob, json, os, statistics, sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

HOME = os.environ.get("SLOTSTREAM_HOME", os.path.expanduser("~/.slotstream"))
M = os.path.join(HOME, "metrics")


def rows(path):
    if not os.path.exists(path):
        return []
    out = []
    for line in open(path):
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return out


def ts(row):
    t = row.get("ts", "")
    try:
        return datetime.fromisoformat(t.replace("Z", "+00:00"))
    except ValueError:
        return None


def med(vals):
    vals = [v for v in vals if isinstance(v, (int, float))]
    return round(statistics.median(vals), 2) if vals else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hours", type=float, default=24)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    since = datetime.now(timezone.utc) - timedelta(hours=a.hours)

    ex = [r for r in rows(os.path.join(M, "exerciser.jsonl")) if (ts(r) or since) >= since]
    bench = [r for r in rows(os.path.join(M, "bench.jsonl")) if (ts(r) or since) >= since]
    mon = []
    for f in sorted(glob.glob(os.path.join(M, "20*.jsonl"))):
        mon += [r for r in rows(f) if (ts(r) or since) >= since]

    report = {"window_hours": a.hours, "exerciser_runs": len(ex), "bench_runs": len(bench), "monitor_samples": len(mon)}

    # per task
    by = defaultdict(list)
    for r in ex:
        by[r["task"]].append(r)
    tasks = {}
    for name, rs in sorted(by.items()):
        tasks[name] = {
            "runs": len(rs), "ok": sum(r["ok"] for r in rs), "fail": sum(not r["ok"] for r in rs),
            "ttft_med_s": med([r["ttft_s"] for r in rs]), "prefill_med": med([r["prefill_tok_s"] for r in rs]),
            "decode_med": med([r["decode_tok_s"] for r in rs]), "prompt_med": med([r["prompt_tokens"] for r in rs]),
            "cpu_peak_max": max([(r.get("process") or {}).get("cpu_peak") or 0 for r in rs] or [0]),
        }
    report["tasks"] = tasks
    report["failures"] = [{"ts": r["ts"], "task": r["task"], "note": r["note"][:160], "error": (str(r["error"])[:160] if r.get("error") else None)} for r in ex if not r["ok"]][-20:]

    # decode vs cache size (all runs with decode numbers, exerciser + bench)
    buckets = defaultdict(list)
    for r in ex:
        e = (r.get("plan_before") or {}).get("experts_per_layer")
        if e and r.get("decode_tok_s"):
            buckets[e].append(r["decode_tok_s"])
    for r in bench:
        e = (r.get("before") or {}).get("experts_per_layer")
        if e and r.get("decode_tok_s"):
            buckets[e].append(r["decode_tok_s"])
    report["decode_by_experts"] = {str(k): {"n": len(v), "decode_med": med(v)} for k, v in sorted(buckets.items())}

    # monitor
    if mon:
        interval = 30
        press = defaultdict(int)
        for r in mon:
            press[r.get("pressure", "unknown")] += 1
        experts = [r["slotstream"].get("experts_per_layer") for r in mon if r.get("slotstream", {}).get("experts_per_layer")]
        resizes = sum(1 for i in range(1, len(experts)) if experts[i] != experts[i - 1])
        batt = [r for r in mon if isinstance(r.get("battery"), str) and r["battery"].endswith("battery")]
        report["monitor"] = {
            "pressure_minutes": {k: round(v * interval / 60, 1) for k, v in press.items()},
            "experts_min": min(experts) if experts else None, "experts_max": max(experts) if experts else None,
            "cache_resizes": resizes, "on_battery_minutes": round(len(batt) * interval / 60, 1),
            "disk_free_min_gb": min([r["disk_free_gb"] for r in mon if r.get("disk_free_gb") is not None] or [None]) if any(r.get("disk_free_gb") is not None for r in mon) else None,
            "swap_max_mb": max([r["swap_used_mb"] for r in mon if r.get("swap_used_mb") is not None] or [0]),
            "server_down_samples": sum(1 for r in mon if not r.get("slotstream", {}).get("ready")),
        }
    procs = [r["process"] for r in ex if r.get("process")]
    if procs:
        report["server_process"] = {"cpu_peak_max": max(p["cpu_peak"] for p in procs), "cpu_mean_med": med([p["cpu_mean"] for p in procs]), "rss_peak_max_mb": max(p["rss_peak_mb"] for p in procs)}

    if a.json:
        print(json.dumps(report, indent=2))
        return

    print(f"last {a.hours:g}h: {len(ex)} exerciser runs, {len(bench)} bench runs, {len(mon)} monitor samples\n")
    if tasks:
        print(f"{'task':20s} {'runs':>4} {'ok':>3} {'fail':>4} {'prompt':>7} {'TTFT s':>7} {'prefill':>8} {'decode':>7} {'cpu%':>5}")
        for n, t in tasks.items():
            print(f"{n:20s} {t['runs']:4d} {t['ok']:3d} {t['fail']:4d} {str(t['prompt_med']):>7} {str(t['ttft_med_s']):>7} {str(t['prefill_med']):>8} {str(t['decode_med']):>7} {t['cpu_peak_max']:5.0f}")
    if report["failures"]:
        print("\nfailures:")
        for f in report["failures"]:
            print(f"  {f['ts']} {f['task']}: {f['note']} {f['error'] or ''}")
    if report["decode_by_experts"]:
        print("\ndecode tok/s by experts/layer at request start:")
        for k, v in report["decode_by_experts"].items():
            print(f"  {k:>4}/layer  n={v['n']:<3} median {v['decode_med']}")
    if "monitor" in report:
        m = report["monitor"]
        print(f"\nmonitor: pressure minutes {m['pressure_minutes']} | experts {m['experts_min']}..{m['experts_max']} with {m['cache_resizes']} resizes | "
              f"on battery {m['on_battery_minutes']} min | disk min {m['disk_free_min_gb']} GiB | swap max {m['swap_max_mb']} MB | server down samples {m['server_down_samples']}")
    if "server_process" in report:
        p = report["server_process"]
        print(f"server process during tasks: cpu peak {p['cpu_peak_max']}%, median mean {p['cpu_mean_med']}%, rss peak {p['rss_peak_max_mb']} MB (Metal memory not included; see size_vram in monitor)")


if __name__ == "__main__":
    main()
