#!/usr/bin/env python3
"""Continuous exerciser for the local Slotstream server.

Runs a rotating suite of realistic and adversarial tasks against the server in the
background, records what each one cost (latency, tokens, process CPU and memory,
system pressure, battery) and whether it behaved, and publishes a small state file
the menu-bar app reads. It yields to real work and can be paused.

Files (under ~/.slotstream):
  metrics/exerciser.jsonl   one row per task run (the evidence)
  exerciser.state.json      live state for the app: current task, counts, last results
  exerciser.pause           pause flag; contents = reason (app toggles it)
  opencode-active           written by the OpenCode plugin while a request is in flight;
                            the exerciser waits while it is fresh
  ctl.env                   shared settings (SLOTSTREAM_PORT, EXERCISER_* knobs)

Settings (env or ctl.env):
  EXERCISER_REPOS            colon-separated source trees for code tasks (default: this repo)
  EXERCISER_GAP_S            idle gap between tasks (default 90)
  EXERCISER_PAUSE_ON_BATTERY 1 = pause while discharging (default 1)
  EXERCISER_MAX_PROMPT       largest prompt the long tasks build, tokens (default 24000)

Usage: exerciser.py            run forever
       exerciser.py --once     run one full cycle and exit
       exerciser.py --task X   run one named task and exit (see TASKS)
       exerciser.py --sweep 4000,8000,16000,24000,32000 [--label name]
                               context sweep: codebase summary at each prompt size, in order,
                               then exit. Rows carry task "sweep-<tokens>" for the report/dashboard.
       exerciser.py --list
"""
import argparse, json, os, random, signal, socket, subprocess, sys, threading, time, urllib.request, urllib.error
from datetime import datetime, timezone

HOME = os.environ.get("SLOTSTREAM_HOME", os.path.expanduser("~/.slotstream"))
_env = os.path.join(HOME, "ctl.env")
if os.path.exists(_env):
    for _line in open(_env):
        if "=" in _line and not _line.startswith("#"):
            k, v = _line.rstrip("\n").split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())

PORT = os.environ.get("SLOTSTREAM_PORT", "11434")
MODEL = os.environ.get("SLOTSTREAM_MODEL", "qwen3.8-flash-next:4bit")
BASE = f"http://127.0.0.1:{PORT}"
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
REPOS = [p for p in os.environ.get("EXERCISER_REPOS", REPO).split(":") if p]
GAP_S = float(os.environ.get("EXERCISER_GAP_S", "90"))
PAUSE_ON_BATTERY = os.environ.get("EXERCISER_PAUSE_ON_BATTERY", "1") == "1"
MAX_PROMPT = int(os.environ.get("EXERCISER_MAX_PROMPT", "24000"))
OUT = os.path.join(HOME, "metrics", "exerciser.jsonl")
STATE = os.path.join(HOME, "exerciser.state.json")
PAUSE = os.path.join(HOME, "exerciser.pause")
ACTIVE = os.path.join(HOME, "opencode-active")
SOURCE_EXT = (".ts", ".swift", ".py", ".sh", ".md", ".js", ".go", ".rs", ".c", ".h", ".cpp", ".java", ".kt")

stop = False


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def approx_tokens(text):
    return len(text) // 4 + 4


# ---------- system sampling ----------

def sh(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return ""


def server_pid():
    out = sh(["pgrep", "-f", "slotstream serve"]).split()
    return int(out[0]) if out else None


def proc_sample(pid):
    if not pid:
        return None
    out = sh(["ps", "-o", "rss=,%cpu=", "-p", str(pid)]).split()
    if len(out) < 2:
        return None
    return {"rss_mb": int(out[0]) // 1024, "cpu": float(out[1].replace(",", "."))}


def system_sample():
    level = sh(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"]).strip()
    free = None
    for line in sh(["memory_pressure"]).splitlines():
        if "free percentage" in line:
            free = int(line.split(":")[1].strip().rstrip("%"))
    batt_out = sh(["pmset", "-g", "batt"])
    battery, discharging = None, False
    for line in batt_out.splitlines():
        if "InternalBattery" in line:
            pct = line.split("\t")[1].split(";")[0].strip().rstrip("%") if "\t" in line else ""
            battery = int(pct) if pct.isdigit() else None
            discharging = "discharging" in line
    swap = sh(["sysctl", "-n", "vm.swapusage"])
    swap_mb = None
    if "used" in swap:
        swap_mb = float(swap.split("used =")[1].split("M")[0].strip().replace(",", "."))
    return {
        "pressure": {"1": "normal", "2": "warning", "4": "critical"}.get(level, "unknown"),
        "free_percent": free,
        "battery": battery,
        "discharging": discharging,
        "swap_used_mb": swap_mb,
    }


class ProcWatch:
    """Samples the server process once a second during a task; reports peak and mean."""

    def __init__(self):
        self.samples = []
        self._stop = threading.Event()
        self._t = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        pid = server_pid()
        while not self._stop.is_set():
            s = proc_sample(pid)
            if s:
                self.samples.append(s)
            self._stop.wait(1)

    def __enter__(self):
        self._t.start()
        return self

    def __exit__(self, *a):
        self._stop.set()
        self._t.join(2)

    def summary(self):
        if not self.samples:
            return None
        cpu = [s["cpu"] for s in self.samples]
        rss = [s["rss_mb"] for s in self.samples]
        return {"cpu_mean": round(sum(cpu) / len(cpu), 1), "cpu_peak": max(cpu), "rss_peak_mb": max(rss), "samples": len(self.samples)}


# ---------- server ----------

def api(path, body=None, timeout=5):
    req = urllib.request.Request(BASE + path, method="POST" if body is not None else "GET")
    data = None
    if body is not None:
        req.add_header("content-type", "application/json")
        data = json.dumps(body).encode()
    try:
        with urllib.request.urlopen(req, data, timeout=timeout) as r:
            return json.load(r)
    except Exception:
        return None


def plan_snapshot():
    show = api("/api/show", {"model": MODEL}) or {}
    d = show.get("details", {})
    p, c = d.get("memory_plan", {}), d.get("prefix_cache", {})
    return {
        "experts_per_layer": p.get("experts_per_layer_cached"), "pool_gb": p.get("pool_gb"),
        "est_prefill_tok_s": p.get("est_prefill_tok_s"), "est_warm_tok_s": p.get("est_warm_tok_s"),
        "prefix_held": c.get("held_tokens"), "prefix_hits": c.get("hits"), "prefix_misses": c.get("misses"),
    }


_progress_written = 0.0


def publish_progress(started, first, output_tokens, prompt_tokens=None, force=False):
    """Writes live request progress into the state file (throttled to 2 s) for the menu-bar app."""
    global _progress_written
    now = time.monotonic()
    if not force and now - _progress_written < 2:
        return
    _progress_written = now
    state["progress"] = {
        "elapsed_s": round(now - started, 1),
        "ttft_s": round(first - started, 2) if first else None,
        "output_tokens": output_tokens,
        "decode_tok_s": round(output_tokens / (now - first), 2) if first and output_tokens and now > first else None,
        "prompt_tokens": prompt_tokens,
    }
    write_state()


def chat(messages, max_tokens=300, tools=None, timeout=1800, abort_after=None, extra=None):
    """Streams one chat completion. Returns a result dict; never raises."""
    body = {"model": MODEL, "messages": messages, "max_tokens": max_tokens, "stream": True,
            "stream_options": {"include_usage": True}, "temperature": 0}
    if tools:
        body["tools"] = tools
    if extra:
        body.update(extra)
    req = urllib.request.Request(BASE + "/v1/chat/completions", json.dumps(body).encode(), {"content-type": "application/json"})
    started = time.monotonic()
    res = {"ttft_s": None, "total_s": None, "prompt_tokens": None, "output_tokens": 0, "text": "", "tool_calls": [],
           "finish": None, "error": None, "aborted": False}
    first = None
    publish_progress(started, None, 0, approx_tokens("".join(m.get("content", "") for m in messages)), force=True)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            for raw in r:
                if abort_after and time.monotonic() - started > abort_after:
                    res["aborted"] = True
                    break
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    ev = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                if ev.get("error"):
                    res["error"] = ev["error"]
                    break
                if ev.get("usage"):
                    res["prompt_tokens"] = ev["usage"].get("prompt_tokens")
                    res["output_tokens"] = ev["usage"].get("completion_tokens") or res["output_tokens"]
                for ch in ev.get("choices", []):
                    d = ch.get("delta", {})
                    piece = d.get("content") or d.get("reasoning_content") or ""
                    if piece or d.get("tool_calls"):
                        if first is None:
                            first = time.monotonic()
                    if piece:
                        res["text"] += piece
                        if not ev.get("usage"):
                            res["output_tokens"] += 1
                        publish_progress(started, first, res["output_tokens"], res["prompt_tokens"])
                    for tc in d.get("tool_calls") or []:
                        idx = tc.get("index", 0)
                        while len(res["tool_calls"]) <= idx:
                            res["tool_calls"].append({"name": "", "arguments": ""})
                        fn = tc.get("function", {})
                        res["tool_calls"][idx]["name"] += fn.get("name") or ""
                        res["tool_calls"][idx]["arguments"] += fn.get("arguments") or ""
                    if ch.get("finish_reason"):
                        res["finish"] = ch["finish_reason"]
    except urllib.error.HTTPError as e:
        body_text = e.read().decode("utf-8", "replace")[:600]
        try:
            res["error"] = json.loads(body_text).get("error", body_text)
        except Exception:
            res["error"] = {"status": e.code, "body": body_text}
    except Exception as e:  # noqa: BLE001
        res["error"] = {"exception": repr(e)}
    ended = time.monotonic()
    state["progress"] = None
    res["ttft_s"] = round(first - started, 2) if first else None
    res["total_s"] = round(ended - started, 2)
    res["decode_tok_s"] = round(res["output_tokens"] / (ended - first), 2) if first and res["output_tokens"] and ended > first else None
    res["prefill_tok_s"] = round(res["prompt_tokens"] / (first - started), 1) if first and res["prompt_tokens"] else None
    return res


# ---------- corpus ----------

def source_files():
    files = []
    for root in REPOS:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in ("node_modules", ".git", ".build", "__pycache__", "dist", "build")]
            for f in filenames:
                if f.endswith(SOURCE_EXT):
                    p = os.path.join(dirpath, f)
                    try:
                        size = os.path.getsize(p)
                    except OSError:
                        continue
                    if 200 < size < 200_000:
                        files.append(p)
    return files


def read(p, limit=None):
    try:
        t = open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""
    return t[:limit] if limit else t


def build_codebase_prompt(target_tokens):
    """Concatenates files from the corpus up to roughly target_tokens."""
    files = source_files()
    random.shuffle(files)
    parts, total = [], 0
    for p in files:
        t = read(p, 60_000)
        cost = approx_tokens(t) + 20
        if total + cost > target_tokens:
            continue
        parts.append(f"### {os.path.relpath(p, REPOS[0]) if p.startswith(REPOS[0]) else p}\n```\n{t}\n```")
        total += cost
        if total > target_tokens * 0.95:
            break
    return "\n\n".join(parts), total, len(parts)


# ---------- tasks ----------
# Each task returns (result_from_chat_or_None, check: dict(ok: bool, note: str), details: dict)

def t_short_chat():
    r = chat([{"role": "user", "content": "In one sentence, what does an expert cache do in a mixture-of-experts model?"}], max_tokens=80)
    ok = not r["error"] and len(r["text"].strip()) > 10
    return r, {"ok": ok, "note": "" if ok else "empty or error"}, {}


def t_code_review():
    files = source_files()
    if not files:
        return None, {"ok": False, "note": "no source files"}, {}
    p = random.choice(files)
    t = read(p, 16_000)
    r = chat([{"role": "system", "content": "You are a careful senior engineer reviewing code."},
              {"role": "user", "content": f"Review this file. List concrete bugs or risks first, then at most three improvements. Be specific and brief.\n\nFile: {os.path.basename(p)}\n```\n{t}\n```"}],
             max_tokens=500)
    ok = not r["error"] and len(r["text"].strip()) > 50
    return r, {"ok": ok, "note": "" if ok else "no review produced"}, {"file": p, "file_chars": len(t)}


def t_codebase_summary(size):
    prompt, est, n = build_codebase_prompt(size)
    if n == 0:
        return None, {"ok": False, "note": "corpus empty"}, {}
    r = chat([{"role": "user", "content": f"Here are {n} files from a codebase. Explain in five bullets what the project does, then name the riskiest file and why.\n\n{prompt}"}],
             max_tokens=400)
    ok = not r["error"] and len(r["text"].strip()) > 50
    return r, {"ok": ok, "note": "" if ok else "no summary produced"}, {"files": n, "est_prompt_tokens": est}


def t_multi_turn():
    files = source_files()
    p = random.choice(files) if files else None
    t = read(p, 8000) if p else "def add(a, b):\n    return a + b\n"
    msgs = [{"role": "user", "content": f"Here is a file:\n```\n{t}\n```\nWhat is its main responsibility? One paragraph."}]
    r1 = chat(msgs, max_tokens=200)
    if r1["error"]:
        return r1, {"ok": False, "note": "turn 1 failed"}, {"turn": 1}
    msgs += [{"role": "assistant", "content": r1["text"]}, {"role": "user", "content": "Name one function in it and describe its inputs and outputs."}]
    r2 = chat(msgs, max_tokens=200)
    if r2["error"]:
        return r2, {"ok": False, "note": "turn 2 failed"}, {"turn": 2, "turn1_ttft_s": r1["ttft_s"]}
    msgs += [{"role": "assistant", "content": r2["text"]}, {"role": "user", "content": "Suggest one test for that function, as code."}]
    r3 = chat(msgs, max_tokens=250)
    reuse = (r1["ttft_s"] or 0) > 0 and (r2["ttft_s"] or 0) < (r1["ttft_s"] or 0)
    ok = not r3["error"] and reuse
    note = "" if ok else ("turn 3 failed" if r3["error"] else f"turn 2 TTFT {r2['ttft_s']}s not below turn 1 {r1['ttft_s']}s (prefix not reused?)")
    r3["prefix_reuse_ok"] = reuse
    return r3, {"ok": ok, "note": note}, {"turn1_ttft_s": r1["ttft_s"], "turn2_ttft_s": r2["ttft_s"], "turn3_ttft_s": r3["ttft_s"], "turns": 3}


TOOLS = [{"type": "function", "function": {
    "name": "read_file",
    "description": "Read a file from the repository",
    "parameters": {"type": "object", "properties": {"path": {"type": "string", "description": "repository-relative path"}}, "required": ["path"]},
}}]


def t_tool_call():
    r = chat([{"role": "system", "content": "You have tools. Use them when needed."},
              {"role": "user", "content": "Read the file scripts/monitor.sh and tell me what it does. Call the tool first."}],
             max_tokens=200, tools=TOOLS)
    called = any(tc["name"] == "read_file" for tc in r["tool_calls"])
    args_ok = False
    for tc in r["tool_calls"]:
        try:
            args_ok = args_ok or "path" in json.loads(tc["arguments"] or "{}")
        except json.JSONDecodeError:
            pass
    ok = not r["error"] and called and args_ok
    note = "" if ok else ("error" if r["error"] else f"no valid tool call (calls={r['tool_calls'][:2]}, text={r['text'][:80]!r})")
    return r, {"ok": ok, "note": note}, {"tool_calls": r["tool_calls"][:3]}


def t_long_generation():
    r = chat([{"role": "user", "content": "Write a detailed design document (at least 1200 words) for a supervisor that keeps a local LLM server healthy on a laptop: lifecycle, memory policy, sleep handling, metrics, failure recovery."}],
             max_tokens=1500)
    ok = not r["error"] and r["output_tokens"] >= 600
    return r, {"ok": ok, "note": "" if ok else f"only {r['output_tokens']} tokens ({r['finish']})"}, {}


def t_context_overflow():
    window = (api("/api/show", {"model": MODEL}) or {}).get("details", {}).get("memory_plan", {}).get("max_context_tokens") or 32768
    filler = "The quick brown fox jumps over the lazy dog. " * (window // 8)
    r = chat([{"role": "user", "content": filler + "\nSummarize."}], max_tokens=50, timeout=120)
    code = (r["error"] or {}).get("code") if isinstance(r["error"], dict) else None
    ok = code == "context_length_exceeded" and r["ttft_s"] is None and r["total_s"] < 60
    note = "" if ok else ("server accepted an over-window prompt" if not r["error"] else f"unexpected refusal ({code}): {str(r['error'])[:120]}")
    return r, {"ok": ok, "note": note}, {"window": window, "error_code": code}


def t_cancel_mid_prefill():
    prompt, est, n = build_codebase_prompt(6000)
    r = chat([{"role": "user", "content": f"Summarize:\n{prompt}"}], max_tokens=50, abort_after=4)
    # The connection is closed by us; the server must notice and be ready for the next request quickly.
    t0 = time.monotonic()
    follow = chat([{"role": "user", "content": "Say OK."}], max_tokens=5, timeout=300)
    recovery_s = round(time.monotonic() - t0, 2)
    ok = not follow["error"] and recovery_s < 90
    follow["cancel_recovery_s"] = recovery_s
    return follow, {"ok": ok, "note": "" if ok else f"follow-up after cancel took {recovery_s}s or failed"}, {"aborted_after_s": 4, "est_prompt_tokens": est, "recovery_s": recovery_s}


def t_concurrent_pair():
    results = [None, None]

    def worker(i, msg):
        results[i] = chat([{"role": "user", "content": msg}], max_tokens=60)

    a = threading.Thread(target=worker, args=(0, "Count from one to ten in words."))
    b = threading.Thread(target=worker, args=(1, "Name three colors."))
    t0 = time.monotonic()
    a.start(); time.sleep(0.5); b.start(); a.join(); b.join()
    wall = round(time.monotonic() - t0, 2)
    ok = all(r and not r["error"] for r in results)
    ttfts = [r["ttft_s"] if r else None for r in results]
    r = results[1] or results[0]
    return r, {"ok": ok, "note": "" if ok else f"errors: {[str(x['error'])[:80] for x in results if x and x['error']]}"}, {"wall_s": wall, "ttfts": ttfts, "queued": (ttfts[1] or 0) > (ttfts[0] or 0)}


def t_json_answer():
    r = chat([{"role": "user", "content": 'Return only JSON: {"languages": [list of three programming languages], "count": 3}'}], max_tokens=80)
    ok = False
    try:
        txt = r["text"].strip()
        if txt.startswith("```"):
            txt = txt.strip("`").split("\n", 1)[1] if "\n" in txt else txt
            txt = txt.rsplit("```", 1)[0]
        obj = json.loads(txt)
        ok = isinstance(obj.get("languages"), list) and len(obj["languages"]) == 3
    except Exception:
        pass
    return r, {"ok": ok and not r["error"], "note": "" if ok else f"not valid JSON: {r['text'][:80]!r}"}, {}


# name -> (fn, weight per cycle, heavy)
TASKS = {
    "short-chat": (t_short_chat, 2, False),
    "code-review": (t_code_review, 2, False),
    "multi-turn": (t_multi_turn, 1, False),
    "tool-call": (t_tool_call, 1, False),
    "json-answer": (t_json_answer, 1, False),
    "codebase-8k": (lambda: t_codebase_summary(8000), 1, True),
    "codebase-16k": (lambda: t_codebase_summary(16000), 1, True),
    "codebase-max": (lambda: t_codebase_summary(MAX_PROMPT), 1, True),
    "long-generation": (t_long_generation, 1, True),
    "context-overflow": (t_context_overflow, 1, False),
    "cancel-mid-prefill": (t_cancel_mid_prefill, 1, False),
    "concurrent-pair": (t_concurrent_pair, 1, False),
}


# ---------- scheduling & state ----------

state = {"started": now(), "cycle": 0, "runs": 0, "ok": 0, "fail": 0, "current": None, "current_started": None,
         "paused": None, "last": [], "by_task": {}, "pid": os.getpid(), "progress": None}


def write_state():
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump({**state, "updated": now()}, f)
    os.replace(tmp, STATE)


def pause_reason():
    if os.path.exists(PAUSE):
        return (read(PAUSE).strip() or "paused")
    if os.path.exists(ACTIVE):
        try:
            age = time.time() - os.path.getmtime(ACTIVE)
            info = json.loads(read(ACTIVE) or "{}")
            if age < 600:
                return f"OpenCode active ({info.get('agent', 'request')}, {int(age)}s ago)"
        except Exception:
            pass
    sysinfo = system_sample()
    if PAUSE_ON_BATTERY and sysinfo["discharging"]:
        return "on battery"
    if sysinfo["pressure"] == "critical":
        return f"memory pressure critical ({sysinfo['free_percent']}% free)"
    if not api("/api/version"):
        return "server not ready"
    return None


def wait_while_paused():
    last = None
    while not stop:
        reason = pause_reason()
        if reason != last:
            state["paused"] = reason
            write_state()
            last = reason
        if reason is None:
            return True
        time.sleep(10)
    return False


def run_task(name):
    fn, _, heavy = TASKS[name]
    state["current"], state["current_started"] = name, now()
    write_state()
    sys_before, plan_before = system_sample(), plan_snapshot()
    with ProcWatch() as pw:
        t0 = time.monotonic()
        try:
            result, check, details = fn()
        except Exception as e:  # noqa: BLE001
            result, check, details = None, {"ok": False, "note": f"task crashed: {e!r}"}, {}
        elapsed = round(time.monotonic() - t0, 2)
    sys_after, plan_after = system_sample(), plan_snapshot()
    row = {
        "ts": now(), "task": name, "label": state.get("label", ""), "cycle": state["cycle"], "ok": check["ok"], "note": check["note"], "elapsed_s": elapsed,
        "ttft_s": result and result.get("ttft_s"), "prefill_tok_s": result and result.get("prefill_tok_s"),
        "decode_tok_s": result and result.get("decode_tok_s"), "prompt_tokens": result and result.get("prompt_tokens"),
        "output_tokens": result and result.get("output_tokens"), "finish": result and result.get("finish"),
        "error": result and result.get("error"), "details": details,
        "process": pw.summary(), "system_before": sys_before, "system_after": sys_after,
        "plan_before": plan_before, "plan_after": plan_after,
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "a") as f:
        f.write(json.dumps(row) + "\n")
    state["runs"] += 1
    state["ok" if check["ok"] else "fail"] += 1
    bt = state["by_task"].setdefault(name, {"ok": 0, "fail": 0})
    bt["ok" if check["ok"] else "fail"] += 1
    state["last"] = ([{k: row[k] for k in ("ts", "task", "ok", "note", "ttft_s", "decode_tok_s", "prompt_tokens", "output_tokens", "elapsed_s")}] + state["last"])[:8]
    state["current"], state["current_started"] = None, None
    write_state()
    print(f"[{row['ts']}] {name}: {'ok' if check['ok'] else 'FAIL'} {check['note']} | prompt {row['prompt_tokens']} ttft {row['ttft_s']} decode {row['decode_tok_s']} | cpu {row['process'] and row['process']['cpu_peak']}%", flush=True)
    return row


def cycle_order():
    order = []
    for name, (_, weight, _) in TASKS.items():
        order += [name] * weight
    random.shuffle(order)
    # keep heavy tasks apart so the machine gets breaks between long prefills
    heavy = [n for n in order if TASKS[n][2]]
    light = [n for n in order if not TASKS[n][2]]
    out = []
    while heavy or light:
        if light:
            out.append(light.pop())
        if light:
            out.append(light.pop())
        if heavy:
            out.append(heavy.pop())
    return out


def main():
    global stop
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--task", choices=sorted(TASKS))
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--gap", type=float, default=GAP_S)
    ap.add_argument("--sweep", help="comma-separated prompt sizes in tokens")
    ap.add_argument("--label", default="")
    args = ap.parse_args()
    if args.list:
        for n, (_, w, h) in TASKS.items():
            print(f"{n:20s} weight {w}  {'heavy' if h else ''}")
        return

    def on_signal(*_):
        global stop
        stop = True
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    if args.task:
        if wait_while_paused():
            run_task(args.task)
        return

    if args.sweep:
        sizes = [int(x) for x in args.sweep.split(",") if x.strip()]
        for size in sizes:
            name = f"sweep-{size}"
            TASKS[name] = (lambda size=size: t_codebase_summary(size), 0, True)
            if not wait_while_paused():
                break
            state["label"] = args.label
            run_task(name)
            time.sleep(min(args.gap, 30))
        return

    print(f"exerciser: {BASE} model {MODEL}; corpus {REPOS}; gap {args.gap}s; state {STATE}", flush=True)
    while not stop:
        state["cycle"] += 1
        for name in cycle_order():
            if stop or not wait_while_paused():
                break
            run_task(name)
            # Rest between tasks, but keep the published state honest: re-evaluate the
            # yield rules every few seconds so the app shows "waiting: OpenCode active"
            # as soon as a real request starts, not only when the next task is due.
            for i in range(int(args.gap)):
                if stop:
                    break
                if i % 5 == 0:
                    reason = pause_reason()
                    if reason != state["paused"]:
                        state["paused"] = reason
                        write_state()
                time.sleep(1)
        if args.once:
            break
    state["current"] = None
    state["paused"] = "stopped"
    write_state()


if __name__ == "__main__":
    main()
