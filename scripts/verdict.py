#!/usr/bin/env python3
"""What this machine can and cannot do with the local model, from what was measured here.

Every line comes from a recorded measurement on this machine: the calibration verdict and
attempts, the exerciser's runs since the current settings took effect, your own OpenCode
turns, and the running server's memory plan. Nothing is estimated. A task with no runs at
the current settings is listed as untested rather than guessed.

Each "cannot" says why, and what kind of limit it is:
  setting   a choice we can change (the fix is named)
  memory    what is free on the machine when measured
  hardware  follows from this machine; only different hardware changes it
  unknown   measured, but the cause is not settled (see CONSTRAINTS.md)

Usage:
  verdict.py          print it
  verdict.py --json   the same, for the app
"""
import json, os, statistics, subprocess, sys, urllib.request
from datetime import datetime, timezone

HOME = os.environ.get("SLOTSTREAM_HOME", os.path.expanduser("~/.slotstream"))
METRICS = os.path.join(HOME, "metrics")
MODEL = os.environ.get("SLOTSTREAM_MODEL", "qwen3.8-flash-next:4bit")


def env_port():
    port = os.environ.get("SLOTSTREAM_PORT")
    path = os.path.join(HOME, "ctl.env")
    if not port and os.path.exists(path):
        for line in open(path):
            if line.startswith("SLOTSTREAM_PORT="):
                port = line.split("=", 1)[1].strip()
    return port or "11434"


def jsonl(name):
    path = os.path.join(METRICS, name) if not name.startswith("/") else name
    rows = []
    try:
        for line in open(path):
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
    except OSError:
        pass
    return rows


def parse_ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        return None


def median(values):
    values = [v for v in values if isinstance(v, (int, float))]
    return statistics.median(values) if values else None


def dur(seconds):
    if seconds is None:
        return "?"
    if seconds < 90:
        return f"{seconds:.0f} s"
    if seconds < 90 * 60:
        return f"{seconds / 60:.0f} min"
    return f"{seconds / 3600:.1f} h"


def tok(n):
    if n is None:
        return "?"
    return f"{n / 1000:.0f}K" if n >= 10_000 else (f"{n / 1000:.1f}K" if n >= 1000 else f"{n}")


def day(ts):
    t = parse_ts(ts) if isinstance(ts, str) else ts
    return t.astimezone().strftime("%-d %b") if t else "?"


def memory_plan():
    try:
        req = urllib.request.Request(f"http://127.0.0.1:{env_port()}/api/show",
                                     data=json.dumps({"name": MODEL}).encode(),
                                     headers={"Content-Type": "application/json"})
        return json.load(urllib.request.urlopen(req, timeout=3))["details"]["memory_plan"]
    except Exception:
        return None


def settings_since():
    """When the current settings took effect: the newest change to what configures the server."""
    times = []
    for name in ("ctl.env", "profile", "calibration.json"):
        try:
            times.append(os.path.getmtime(os.path.join(HOME, name)))
        except OSError:
            pass
    return datetime.fromtimestamp(max(times), timezone.utc) if times else None


def ram_gb():
    """Installed RAM as the Mac is sold (GiB), so it matches the machine's own label."""
    try:
        return int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True,
                                  timeout=5).stdout.strip()) / 2**30
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def machine_name():
    ram = ram_gb()
    try:
        chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True,
                              text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        chip = ""
    return " ".join(b for b in (f"{ram:.0f} GB" if ram else "", chip) if b) or "this machine"


def win(n):
    """Windows are powers of two; print them exactly rather than rounding 65,536 to 66K."""
    return f"{n:,}" if n else "?"


def build():
    now = datetime.now(timezone.utc)
    plan = memory_plan()
    since = settings_since()
    try:
        calibration = json.load(open(os.path.join(HOME, "calibration.json")))
    except (OSError, ValueError):
        calibration = None
    attempts = jsonl(os.path.join(HOME, "calibration-attempts.jsonl"))
    runs_all = [r for r in jsonl("exerciser.jsonl") if not r.get("label")]
    runs = [r for r in runs_all if since is None or (parse_ts(r.get("ts")) or now) >= since]
    turns = jsonl("opencode.jsonl")

    window = (plan or {}).get("max_context_tokens") or (calibration or {}).get("window")
    target = (plan or {}).get("target_gb") or (calibration or {}).get("memory_target_gb")
    keeps = (plan or {}).get("prefix_cache_max_tokens")
    can, cannot, untested = [], [], []

    def by_task(name):
        return [r for r in runs if r.get("task") == name]

    def judge(name, title, good_detail, bad_detail=None, why=None):
        rows = by_task(name)
        if not rows:
            untested.append({"title": title, "detail": "no runs since the current settings took effect"})
            return None
        ok = [r for r in rows if r.get("ok")]
        rate = len(ok) / len(rows)
        evidence = f"{len(ok)} of {len(rows)} runs since {day(since)}"
        if rate >= 0.8:
            can.append({"title": title, "detail": good_detail(ok), "evidence": evidence})
        else:
            item = {"title": title, "detail": (bad_detail or (lambda _r: ""))(rows) or
                    f"worked in {len(ok)} of {len(rows)} runs", "evidence": evidence}
            item.update(why(rows) if why else {"why": "", "kind": "unknown"})
            cannot.append(item)
        return rate

    # 1. The biggest prompt, from calibration.
    if calibration and calibration.get("largest_prompt_ok"):
        can.append({
            "title": f"Read a {tok(calibration['largest_prompt_ok'])}-token prompt",
            "detail": f"{dur(calibration.get('ttft_at_largest_s'))} before the answer starts, "
                      f"at a {win(calibration.get('window'))}-token window",
            "evidence": f"calibration, {day(calibration.get('finished_at'))}"})

    # 2. Everyday tasks, from the exerciser at the current settings.
    judge("short-chat", "Answer a short question",
          lambda ok: f"about {dur(median([r.get('elapsed_s') for r in ok]))} for a short reply")
    judge("tool-call", "Call tools correctly",
          lambda ok: f"asked to read a file, it calls the tool with the right path, "
                     f"in about {dur(median([r.get('elapsed_s') for r in ok]))}")
    judge("json-answer", "Give a structured JSON answer",
          lambda ok: f"valid JSON in about {dur(median([r.get('elapsed_s') for r in ok]))}")
    judge("code-review", "Review a source file",
          lambda ok: f"about {dur(median([r.get('elapsed_s') for r in ok]))} for a "
                     f"{tok(median([r.get('prompt_tokens') for r in ok]))}-token file")

    code = [r for r in runs if r.get("task", "").startswith("codebase-")]
    if code:
        ok = [r for r in code if r.get("ok")]
        sizes = []
        for name in ("codebase-8k", "codebase-16k", "codebase-max"):
            rows = [r for r in ok if r["task"] == name]
            if rows:
                sizes.append(f"{tok(median([r.get('prompt_tokens') for r in rows]))} in "
                             f"{dur(median([r.get('ttft_s') for r in rows]))}")
        largest = max((r.get("prompt_tokens") or 0 for r in ok), default=0)
        entry = {"title": f"Summarise {tok(largest)} tokens of code" if ok else "Summarise code",
                 "detail": "time to first token: " + ", ".join(sizes) if sizes else "",
                 "evidence": f"{len(ok)} of {len(code)} runs since {day(since)}"}
        if len(ok) / len(code) >= 0.8:
            can.append(entry)
        else:
            entry.update({"why": "", "kind": "unknown"})
            cannot.append(entry)

    judge("multi-turn", "Hold a short conversation",
          lambda ok: f"follow-up turns start in about "
                     f"{dur(median([(r.get('details') or {}).get('turn2_ttft_s') for r in ok]))}")

    def long_conversation_why(rows):
        size = median([r.get("prompt_tokens") for r in rows])
        before = [r for r in runs_all if r.get("task") == "multi-turn-long" and r.get("ok")
                  and since and (parse_ts(r.get("ts")) or now) < since]
        why = (f"the server keeps only {keeps:,} tokens of conversation at these settings, "
               f"so each follow-up re-reads all {tok(size)}") if keeps else \
              "the conversation is not kept between turns at these settings"
        fix = "a smaller window leaves memory to keep the whole conversation"
        if before:
            fix += f"; it passed at earlier settings on {day(before[-1]['ts'])}"
        return {"why": why, "kind": "setting", "fix": fix}

    judge("multi-turn-long",
          f"Keep a {tok(median([r.get('prompt_tokens') for r in by_task('multi-turn-long')]) or 20000)}"
          "-token conversation between turns",
          lambda ok: f"follow-up turns start in about "
                     f"{dur(median([(r.get('details') or {}).get('turn2_ttft_s') for r in ok]))}",
          bad_detail=lambda rows: (
              f"the second turn waited {dur(median([(r.get('details') or {}).get('turn2_ttft_s') for r in rows]))}, "
              f"as long as the first ({dur(median([(r.get('details') or {}).get('turn1_ttft_s') for r in rows]))})"),
          why=long_conversation_why)

    judge("long-generation", "Write a long answer",
          lambda ok: f"{median([r.get('output_tokens') for r in ok]):,.0f} tokens in "
                     f"{dur(median([r.get('elapsed_s') for r in ok]))}")
    judge("cancel-mid-prefill", "Stop a request and carry on",
          lambda ok: f"serving again {dur(median([(r.get('details') or {}).get('recovery_s') for r in ok]))} "
                     "after a cancel")

    pairs = by_task("concurrent-pair")
    if pairs and all(r.get("ok") for r in pairs):
        queued = [r for r in pairs if (r.get("details") or {}).get("queued")]
        waits = [max((r.get("details") or {}).get("ttfts") or [0]) for r in queued]
        can.append({"title": "Take two requests at once",
                    "detail": (f"one after the other: the second waits about {dur(median(waits))}"
                               if queued else "both answered"),
                    "evidence": f"{len(pairs)} runs since {day(since)}"})
    elif pairs:
        judge("concurrent-pair", "Take two requests at once", lambda ok: "")

    # 3. Bigger windows, from the calibration attempts at the current memory target.
    if window and target:
        refused = sorted({a["window"] for a in attempts
                          if a.get("kind") == "start" and a.get("window", 0) > window
                          and abs((a.get("target_gb") or 0) - target) < 0.05 and not a.get("ok")})
        started = {a["window"] for a in attempts if a.get("kind") == "start" and a.get("ok")
                   and abs((a.get("target_gb") or 0) - target) < 0.05}
        refused = [w for w in refused if w not in started]
        if refused:
            best = max((a for a in attempts if a.get("kind") == "prompt" and a.get("ok")
                        and (a.get("prompt_tokens") or 0) > (calibration or {}).get("largest_prompt_ok", 0)),
                       key=lambda a: a.get("prompt_tokens") or 0, default=None)
            why = f"calibration found {target:.1f} GB free for the server with your apps open"
            fix = "more free memory"
            if best:
                fix += (f": with {best['target_gb']:.1f} GB on {day(best['ts'])}, a {win(best['window'])}-token "
                        f"window read a {tok(best['prompt_tokens'])}-token prompt")
            available = (plan or {}).get("device_available_gb")
            if available and available - target >= 3:
                fix += f". {available:.1f} GB is reclaimable right now, so measuring again may find more"
            cannot.append({
                "title": f"Use a window larger than {win(window)} tokens",
                "detail": ", ".join(win(w) for w in refused) + f" would not start at {target:.1f} GB",
                "why": why, "kind": "memory", "fix": fix,
                "evidence": f"calibration attempts, {day(max(a['ts'] for a in attempts))}"})

    # 4. Speed: generation is set by the hardware, prefill slowdown is not yet explained.
    decode = median([r.get("decode_tok_s") for r in runs if r.get("ok") and r.get("task") != "tool-call"])
    if decode:
        cached, total = (plan or {}).get("experts_per_layer_cached"), None
        why = "most of the model's experts do not fit in memory and are read from the SSD for every token"
        if cached:
            why = (f"only {cached} of each layer's experts fit in memory at these settings; "
                   "the rest are read from the SSD for every token")
        ram = ram_gb()
        cannot.append({
            "title": "Write quickly",
            "detail": f"{decode:.1f} tokens a second: a 300-token answer takes about {dur(300 / decode)}",
            "why": why, "kind": "hardware",
            "fix": f"more memory than this Mac's {ram:.0f} GB caches more experts" if ram else "more memory",
            "evidence": f"{len(runs)} runs since {day(since)}"})

    probes = [a for a in attempts if a.get("kind") == "prompt" and a.get("ok") and a.get("prefill_decay")]
    if probes:
        p = max(probes, key=lambda a: a.get("prompt_tokens") or 0)
        d = p["prefill_decay"]
        if p.get("ttft_s", 0) > 600:
            cannot.append({
                "title": "Start quickly on a large prompt",
                "detail": f"a {tok(p['prompt_tokens'])}-token prompt took {dur(p['ttft_s'])}; reading slowed "
                          f"from {d.get('first_tok_s', 0):.0f} to {d.get('last_tok_s', 0):.0f} tokens a second "
                          "as it grew",
                "why": "the slowdown is steeper than attention alone explains, and the cause is not settled",
                "kind": "unknown", "fix": "under investigation (CONSTRAINTS.md, 'Still to decide')",
                "evidence": f"calibration probe, {day(p['ts'])}"})

    # 5. Your own use.
    real = None
    if turns:
        ok = [t for t in turns if t.get("ok")]
        follow = [t for t in ok if (t.get("cacheHitRate") or 0) >= 80]
        last = turns[-1]
        real = {
            "last_used": last.get("ts"),
            "turns": len(turns), "failed": len(turns) - len(ok),
            "detail": (f"{len(turns)} turns, last on {day(last.get('ts'))}. Follow-ups started in a median "
                       f"{dur((median([t.get('ttftMs') for t in follow]) or 0) / 1000)} with "
                       f"{median([t.get('cacheHitRate') for t in follow]):.0f}% of a "
                       f"{tok(median([t.get('promptTokens') for t in follow]))}-token prompt reused, "
                       f"at a {win(int(median([t.get('contextLimit') for t in follow])))}-token window") if follow else
                      f"{len(turns)} turns, last on {day(last.get('ts'))}"}
        size = median([t.get("promptTokens") for t in follow]) if follow else None
        if keeps and size and keeps < size:
            real["warning"] = (f"At today's settings the server keeps {keeps:,} tokens, less than those "
                               f"{tok(size)}-token prompts, so each follow-up would re-read the whole prompt.")

    headline_bits = []
    if calibration and calibration.get("largest_prompt_ok"):
        headline_bits.append(f"reads up to {tok(calibration['largest_prompt_ok'])} tokens")
    if decode:
        headline_bits.append(f"writes at {decode:.1f} tokens a second")
    headline = ("It " + " and ".join(headline_bits) + ".") if headline_bits else "Nothing measured yet."
    order = {"setting": 0, "memory": 1, "unknown": 2, "hardware": 3}
    cannot.sort(key=lambda c: order.get(c.get("kind"), 9))
    return {
        "generated_at": now.isoformat(timespec="seconds"),
        "headline": headline,
        "machine": machine_name(),
        "settings": {"window": window, "memory_gb": target, "keeps_tokens": keeps,
                     "since": since.isoformat(timespec="seconds") if since else None,
                     "server_running": plan is not None},
        "can": can, "cannot": cannot, "untested": untested, "your_use": real,
    }


def show(v):
    s = v["settings"]
    print(v["headline"])
    bits = [v.get("machine") or "this machine"]
    if s["window"]:
        bits.append(f"{s['window']:,}-token window")
    if s["memory_gb"]:
        bits.append(f"{s['memory_gb']:.1f} GB")
    print("  " + ", ".join(bits) + (f", settings since {day(s['since'])}" if s["since"] else ""))
    print("\nCAN")
    for c in v["can"]:
        print(f"  ✓ {c['title']}: {c['detail']}  [{c['evidence']}]")
    print("\nCAN'T")
    for c in v["cannot"]:
        print(f"  ✗ {c['title']}: {c['detail']}  [{c['evidence']}]")
        print(f"      why ({c['kind']}): {c['why']}")
        if c.get("fix"):
            print(f"      would take: {c['fix']}")
    if v["untested"]:
        print("\nNOT TESTED AT THESE SETTINGS")
        for c in v["untested"]:
            print(f"  ? {c['title']}")
    if v["your_use"]:
        print("\nYOUR OWN SESSIONS")
        print("  " + v["your_use"]["detail"])
        if v["your_use"].get("warning"):
            print("  " + v["your_use"]["warning"])


if __name__ == "__main__":
    verdict = build()
    if "--json" in sys.argv:
        json.dump(verdict, sys.stdout, indent=1)
        print()
    else:
        show(verdict)
