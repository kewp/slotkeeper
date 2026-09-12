#!/usr/bin/env python3
"""Summarize what the exerciser, benchmark and monitor have recorded.

Usage: report.py [--hours N] [--json]     (default: last 24 hours)

Your own OpenCode sessions come first: every assistant message sent to the local
provider, read from OpenCode's database (~/.local/share/opencode/opencode.db, read-only)
and joined with the plugin's rows in ~/.slotstream/metrics/opencode.jsonl when present:
  - requests, sessions, errors by kind, and how long the model was busy for you
  - TTFT by prompt size, and follow-up turns versus cold prompts (is the prefix reused?)
  - decode rate
Then the synthetic evidence from ~/.slotstream/metrics/{exerciser.jsonl,bench.jsonl,YYYY-MM-DD.jsonl}:
  - pass/fail per task with median TTFT, prefill and decode rates
  - failures and their notes
  - decode rate versus expert-cache size (does more cache actually help?)
  - pressure minutes, cache resize events, battery time, disk floor
  - server process CPU/RSS peaks during tasks
"""
import argparse, glob, json, os, sqlite3, statistics, sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

HOME = os.environ.get("SLOTSTREAM_HOME", os.path.expanduser("~/.slotstream"))
# Shared settings (port, model, knobs) live in ctl.env, as they do for the other scripts.
_env = os.path.join(HOME, "ctl.env")
if os.path.exists(_env):
    for _line in open(_env):
        if "=" in _line and not _line.startswith("#"):
            _k, _v = _line.rstrip("\n").split("=", 1)
            os.environ.setdefault(_k.strip(), _v.strip())
M = os.path.join(HOME, "metrics")
OPENCODE_DB = os.environ.get("OPENCODE_DB", os.path.expanduser("~/.local/share/opencode/opencode.db"))
PROVIDER = os.environ.get("SLOTSTREAM_PROVIDER_ID", "slotstream")
def prompt_buckets(window=None):
    """Size bands scaled to the server's window, so the table reads the same on any machine."""
    if not window:
        try:
            import urllib.request
            port = os.environ.get("SLOTSTREAM_PORT", "11434")
            req = urllib.request.Request(f"http://127.0.0.1:{port}/api/show",
                                         data=b'{"name":"' + os.environ.get("SLOTSTREAM_MODEL", "qwen3.8-flash-next:4bit").encode() + b'"}',
                                         headers={"Content-Type": "application/json"})
            window = json.load(urllib.request.urlopen(req, timeout=5))["details"]["memory_plan"]["max_context_tokens"]
        except Exception:
            window = 32768
    edges = [int(window * f) for f in (0.0625, 0.25, 0.5, 0.75)]
    labels = [f"<{edges[0] // 1000}K"] + [f"{a // 1000}-{b // 1000}K" for a, b in zip(edges, edges[1:])] + [f"{edges[-1] // 1000}K+"]
    bounds = [0] + edges + [10**9]
    return [(lo, hi, label) for lo, hi, label in zip(bounds, bounds[1:], labels)]


def rows_of(path):
    return rows(path)


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


def pct(vals, q):
    vals = sorted(v for v in vals if isinstance(v, (int, float)))
    return round(vals[min(len(vals) - 1, int(q * len(vals)))], 1) if vals else None


def error_kind(err):
    """OpenCode stores provider errors as {name, data: {message}}; the message may be Slotstream's JSON body."""
    if not err:
        return None
    if err.get("name") == "MessageAbortedError":
        return "aborted"
    msg = str((err.get("data") or {}).get("message", ""))
    try:
        code = json.loads(msg).get("code")
        if code:
            return code
    except (ValueError, AttributeError):
        pass
    for code in ("insufficient_memory", "prefill_wait_exceeded", "prefill_deadline_exceeded", "context_length_exceeded"):
        if code in msg:
            return code
    return "other"


def opencode_requests(since):
    """One dict per assistant message on the local provider since `since`, oldest first.

    TTFT is the first text, reasoning or tool part's start minus the message's creation;
    a follow-up is a turn whose prompt adds at most a quarter to the previous turn's
    prompt plus output in the same session and agent, which is what prefix reuse serves."""
    if not os.path.exists(OPENCODE_DB):
        return []
    try:
        db = sqlite3.connect(f"file:{OPENCODE_DB}?mode=ro", uri=True, timeout=5)
        rows = db.execute("""
            select m.id, m.session_id, m.data,
              (select min(coalesce(json_extract(p.data,'$.time.start'), json_extract(p.data,'$.state.time.start')))
                 from part p where p.message_id = m.id
                  and json_extract(p.data,'$.type') in ('text','reasoning','tool'))
            from message m
            where m.time_created >= ? and json_extract(m.data,'$.providerID') = ?
              and json_extract(m.data,'$.role') = 'assistant'
            order by m.time_created""", (int(since.timestamp() * 1000), PROVIDER)).fetchall()
    except sqlite3.Error as e:
        print(f"(OpenCode database unreadable: {e})", file=sys.stderr)
        return []
    plugin = {r.get("messageID"): r for r in rows_of(os.path.join(M, "opencode.jsonl"))}
    out, last = [], {}
    for mid, sid, data, first in rows:
        d = json.loads(data)
        t = d.get("time") or {}
        tok = d.get("tokens") or {}
        cache = tok.get("cache") or {}
        prompt = (tok.get("input") or 0) + (cache.get("read") or 0) + (cache.get("write") or 0)
        output = tok.get("output") or 0
        created, done = t.get("created"), t.get("completed")
        ttft = (first - created) / 1000 if first and created and first >= created else None
        decode_s = (done - first) / 1000 if done and first and done > first else None
        key = (sid, d.get("agent"))
        prev = last.get(key)
        followup = bool(prev and prompt >= 2000 and prompt - (prev[0] + prev[1]) <= 0.25 * prompt)
        if prompt:
            last[key] = (prompt, output)
        err = error_kind(d.get("error"))
        if not err and done is None:
            err = "in flight"  # still generating: no completion time yet, so it is not a result
        elif not err and not prompt and not output and d.get("finish") in (None, "unknown"):
            # A step that consumed and produced nothing: on 2026-09-11 OpenCode looped
            # 3,562 of these in three minutes against the server. A failure, not a request.
            err = "empty"
        row = {"id": mid, "session": sid, "agent": d.get("agent"), "ts": created, "prompt": prompt, "output": output,
               "ttft_s": ttft, "decode_tok_s": round(output / decode_s, 2) if decode_s and output > 1 else None,
               "total_s": (done - created) / 1000 if done and created else None, "error": err, "followup": followup,
               "cwd": (d.get("path") or {}).get("cwd")}
        extra = plugin.get(mid)
        if extra:
            row["experts_per_layer"] = extra.get("expertsCachedPerLayer")
            row["pressure"] = extra.get("pressure")
            if extra.get("ttftMs") is not None:
                row["ttft_s"] = extra["ttftMs"] / 1000  # the plugin's stopwatch is the exact one
        out.append(row)
    return out


def opencode_summary(reqs):
    if not reqs:
        return None
    ok = [r for r in reqs if not r["error"]]
    kinds = defaultdict(int)
    for r in reqs:
        if r["error"]:
            kinds[r["error"]] += 1
    buckets = {}
    for lo, hi, label in prompt_buckets():
        rs = [r for r in ok if lo <= r["prompt"] < hi and r["ttft_s"] is not None]
        if rs:
            buckets[label] = {"n": len(rs), "ttft_med_s": med([r["ttft_s"] for r in rs]), "ttft_p90_s": pct([r["ttft_s"] for r in rs], 0.9),
                              "followups": sum(r["followup"] for r in rs)}
    def split(rs):
        return {"n": len(rs), "ttft_med_s": med([r["ttft_s"] for r in rs]), "prompt_med": med([r["prompt"] for r in rs])}
    big = [r for r in ok if r["prompt"] >= 8000 and r["ttft_s"] is not None]
    return {
        "requests": len(reqs), "sessions": len({r["session"] for r in reqs}), "errors": dict(kinds),
        "busy_hours": round(sum(r["total_s"] or 0 for r in reqs) / 3600, 2),
        "prompt_med": med([r["prompt"] for r in ok]), "prompt_p90": pct([r["prompt"] for r in ok], 0.9),
        "output_med": med([r["output"] for r in ok]),
        "ttft_med_s": med([r["ttft_s"] for r in ok]), "ttft_p90_s": pct([r["ttft_s"] for r in ok], 0.9),
        "decode_med": med([r["decode_tok_s"] for r in ok]),
        "ttft_by_prompt": buckets,
        # Above 8K a cold prompt costs minutes; a reused prefix should make a follow-up cost seconds.
        "over_8k_followup": split([r for r in big if r["followup"]]), "over_8k_cold": split([r for r in big if not r["followup"]]),
        "recent_errors": grouped_errors(reqs)[-8:],
    }


def grouped_errors(reqs):
    """Consecutive errors of one kind in one session collapse into a single line with a count."""
    out = []
    for r in reqs:
        if not r["error"] or r["error"] == "in flight":
            continue
        stamp = datetime.fromtimestamp(r["ts"] / 1000, timezone.utc).astimezone().isoformat(timespec="seconds")
        if out and out[-1]["session"] == r["session"] and out[-1]["kind"] == r["error"]:
            out[-1]["count"] += 1
            out[-1]["last"] = stamp
            continue
        out.append({"ts": stamp, "last": stamp, "kind": r["error"], "count": 1, "session": r["session"],
                    "prompt": r["prompt"], "pressure": r.get("pressure"), "cwd": r.get("cwd")})
    return out


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
    report["opencode"] = opencode_summary(opencode_requests(since))

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

    oc = report["opencode"]
    if oc:
        inflight = oc["errors"].pop("in flight", 0)
        answered = oc["requests"] - sum(oc["errors"].values()) - inflight
        print(f"your OpenCode sessions on the local model, last {a.hours:g}h: {answered} answered, {sum(oc['errors'].values())} failed, "
              f"{oc['sessions']} sessions, model busy {oc['busy_hours']} h"
              + (f", {inflight} still generating" if inflight else ""))
        if oc["errors"]:
            print("  failures by kind: " + ", ".join(f"{k} {v}" for k, v in sorted(oc["errors"].items(), key=lambda kv: -kv[1])))
        print(f"  prompt median {oc['prompt_med']} tok (p90 {oc['prompt_p90']}), output median {oc['output_med']} | "
              f"TTFT median {oc['ttft_med_s']} s (p90 {oc['ttft_p90_s']}) | decode median {oc['decode_med']} tok/s")
        if oc["ttft_by_prompt"]:
            print("  TTFT by prompt size:  " + "   ".join(
                f"{k}: n={v['n']} med {v['ttft_med_s']} s p90 {v['ttft_p90_s']} s" for k, v in oc["ttft_by_prompt"].items()))
        f, c = oc["over_8k_followup"], oc["over_8k_cold"]
        if f["n"] or c["n"]:
            print(f"  prompts over 8K: follow-up turns n={f['n']} TTFT median {f['ttft_med_s']} s | cold n={c['n']} TTFT median {c['ttft_med_s']} s")
        for e in oc["recent_errors"]:
            times = f"{e['count']}x {e['ts']} .. {e['last'][11:19]}" if e["count"] > 1 else e["ts"]
            print(f"  error {times} {e['kind']}" + (f" prompt {e['prompt']}" if e["prompt"] else "")
                  + (f" pressure {e['pressure']}" if e.get("pressure") else "") + (f" in {e['cwd']}" if e.get("cwd") else ""))
        print()
    else:
        print(f"no OpenCode requests to provider '{PROVIDER}' in the last {a.hours:g}h\n")
    print(f"synthetic, last {a.hours:g}h: {len(ex)} exerciser runs, {len(bench)} bench runs, {len(mon)} monitor samples\n")
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
