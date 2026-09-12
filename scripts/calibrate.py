#!/usr/bin/env python3
"""Measure what this machine can actually handle, and write down the answer.

Runs real requests at increasing prompt sizes, steps the context window down when a
size fails for memory, and stops when a window carries prompts up to three quarters of
itself. The result goes to ~/.slotstream/calibration.json and is what the app shows:

    "up to 24,000-token prompts at a 32,768 window, about 60 s to the first token"

It restarts the server to change the window, so it is something you run once on a new
machine (or after changing memory settings), not while you are working. It refuses to
start while your own OpenCode session is active.

Usage:
  calibrate.py                 full run: pick a window, find the largest prompt it carries
  calibrate.py --quick         three sizes per window instead of four
  calibrate.py --window 32768  test one window only
  calibrate.py --show          print the last calibration without measuring
  calibrate.py --auto          keep the answer current on its own: waits until you are away,
                               measures when there is no valid calibration, then rechecks hourly
                               (stop it with ~/.slotstream/calibrate.pause, or from the app)
"""
import argparse, importlib.util, json, os, subprocess, sys, time
from datetime import datetime, timezone

HOME = os.environ.get("SLOTSTREAM_HOME", os.path.expanduser("~/.slotstream"))
_env = os.path.join(HOME, "ctl.env")
if os.path.exists(_env):
    for _line in open(_env):
        if "=" in _line and not _line.startswith("#"):
            _k, _v = _line.rstrip("\n").split("=", 1)
            os.environ.setdefault(_k.strip(), _v.strip())
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULT = os.path.join(HOME, "calibration.json")
CTL = os.path.join(REPO, "scripts", "slotkeeper")
ACTIVE = os.path.join(HOME, "opencode-active")
PAUSE = os.path.join(HOME, "calibrate.pause")
PROGRESS = os.path.join(HOME, "calibration.progress.json")
ATTEMPTS = os.path.join(HOME, "calibration-attempts.jsonl")
JOBS = os.path.join(HOME, "jobs", "running")
STALE_DAYS = 30
IDLE_MINUTES = 30       # how long you must be away before it takes the server
NIGHT_HOURS = (0, 7)
MIN_TARGET_GB = 8.5      # below this the planner refuses: floor cache plus the fixed footprint


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(REPO, "scripts", f"{name}.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def ctl(*args, timeout=600):
    return subprocess.run(["bash", CTL] + list(args), capture_output=True, text=True, timeout=timeout)


def busy():
    if os.path.exists(ACTIVE) and time.time() - os.path.getmtime(ACTIVE) < 600:
        return "your OpenCode session is active; calibration restarts the server"
    return None


def idle_minutes():
    """Minutes since the last keyboard or mouse input."""
    try:
        out = subprocess.run(["ioreg", "-c", "IOHIDSystem", "-d", "4"], capture_output=True,
                             text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        if '"HIDIdleTime"' in line:
            try:
                return int(line.rsplit("=", 1)[1].strip()) / 1e9 / 60
            except ValueError:
                return None
    return None


def blocked_for_auto():
    """Why the automatic run should not take the server right now, or None.

    Calibration restarts the server and loads it for several minutes, so it only runs
    when you are demonstrably not there: at night, or after half an hour away."""
    if os.path.exists(PAUSE):
        return (open(PAUSE).read().strip() or "automatic calibration is stopped")
    if (why := busy()):
        return why
    if os.path.isdir(JOBS) and any(f.endswith(".json") for f in os.listdir(JOBS)):
        return "a job is running"
    mine = str(os.getpid())
    others = [pid for pid in subprocess.run(["pgrep", "-f", "calibrate.py"], capture_output=True,
                                            text=True).stdout.split() if pid != mine]
    if others:
        return "a calibration is already running"
    if "discharging" in subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True).stdout:
        return "on battery"
    hour = datetime.now().hour
    if NIGHT_HOURS[0] <= hour < NIGHT_HOURS[1]:
        return None
    idle = idle_minutes()
    if idle is None or idle < IDLE_MINUTES:
        return f"you are using the machine" + (f" ({idle:.0f} min idle)" if idle is not None else "")
    return None


def current(result=None):
    """Whether the stored calibration still describes this setup."""
    if result is None:
        if not os.path.exists(RESULT):
            return False, "never measured"
        try:
            with open(RESULT) as f:
                result = json.load(f)
        except ValueError:
            return False, "unreadable"
    if result.get("machine") != _machine_description():
        return False, "different machine"
    if result.get("ram_percent") != os.environ.get("SLOTSTREAM_MAX_RAM_PERCENT", "70"):
        return False, "memory settings changed"
    binary = os.path.join(HOME, "bin", "slotstream")
    if os.path.exists(binary) and result.get("finished_at"):
        built = datetime.fromtimestamp(os.path.getmtime(binary), timezone.utc)
        if built > datetime.fromisoformat(result["finished_at"]):
            return False, "the server was rebuilt since"
    age = datetime.now(timezone.utc) - datetime.fromisoformat(result["finished_at"])
    if age.days > STALE_DAYS:
        return False, f"measured {age.days} days ago"
    return True, "current"


def auto(args):
    """Keep the answer current without being asked, and stay out of the way."""
    print(f"auto calibration: checking hourly; stop with {PAUSE}", flush=True)
    while True:
        ok, why = current()
        if ok:
            time.sleep(3600)
            continue
        hold = blocked_for_auto()
        if hold:
            print(f"waiting ({why}): {hold}", flush=True)
            time.sleep(600)
            continue
        print(f"calibrating: {why}", flush=True)
        try:
            run(args)
        except Exception as e:                      # a calibration must never take the machine down
            print(f"calibration failed: {e}", file=sys.stderr, flush=True)
            time.sleep(3600)


def progress(**fields):
    """Publish what calibration is doing right now, so the app can show it live."""
    state = {}
    if os.path.exists(PROGRESS):
        try:
            with open(PROGRESS) as f:
                state = json.load(f)
        except ValueError:
            state = {}
    state.update(fields)
    state["updated"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    try:
        os.makedirs(HOME, exist_ok=True)
        tmp = PROGRESS + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, PROGRESS)
    except OSError:
        pass


def log_attempt(**fields):
    """Append one attempt to the permanent record, so every run can be compared later."""
    line = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), **fields}
    try:
        os.makedirs(HOME, exist_ok=True)
        with open(ATTEMPTS, "a") as f:
            f.write(json.dumps(line) + "\n")
    except OSError:
        pass


def note_attempt(**fields):
    """Record one configuration we tried and how it went, for the app to show live."""
    tried = []
    if os.path.exists(PROGRESS):
        try:
            with open(PROGRESS) as f:
                tried = json.load(f).get("attempts", [])
        except ValueError:
            tried = []
    tried.append({**fields, "at": datetime.now(timezone.utc).isoformat(timespec="seconds")})
    progress(attempts=tried[-20:])


def clear_progress():
    try:
        os.remove(PROGRESS)
    except OSError:
        pass


def measure(exerciser, size, label):
    """One real request at about `size` prompt tokens. Returns a row, never raises."""
    prompt, est, files = exerciser.build_codebase_prompt(size)
    if not files:
        return {"size": size, "ok": False, "note": "no source files to build a prompt from"}
    t0 = time.monotonic()
    result = exerciser.chat(
        [{"role": "user", "content": f"Summarise in two sentences what these files do.\n\n{prompt}"}],
        max_tokens=64)
    row = {"size": size, "label": label, "requested_tokens": est,
           "prompt_tokens": result.get("prompt_tokens"), "ttft_s": result.get("ttft_s"),
           "prefill_tok_s": result.get("prefill_tok_s"), "decode_tok_s": result.get("decode_tok_s"),
           "elapsed_s": round(time.monotonic() - t0, 1),
           "error": (result.get("error") or {}).get("code") if isinstance(result.get("error"), dict) else result.get("error")}
    row["ok"] = not row["error"] and bool(result.get("text", "").strip())
    record(exerciser, row, result)
    return row


def log_probe(row, retention):
    reason = row.get("error") or ""
    if isinstance(result_error := row.get("error"), str) and result_error == "insufficient_memory":
        reason = server_refusal() or result_error
    log_attempt(kind="prompt", window=row.get("window"), target_gb=row.get("target_gb"),
                retention=retention or "default", size=row.get("size"),
                prompt_tokens=row.get("prompt_tokens"), ok=row.get("ok"),
                ttft_s=row.get("ttft_s"), prefill_tok_s=row.get("prefill_tok_s"),
                decode_tok_s=row.get("decode_tok_s"), elapsed_s=row.get("elapsed_s"),
                reason=reason or ("answered" if row.get("ok") else "no answer"))


def record(exerciser, row, result):
    """Append the probe to the same metrics file the report and the app already read."""
    try:
        plan = exerciser.plan_snapshot()
    except Exception:
        plan = None
    line = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
            "task": row["label"], "label": "calibration", "ok": row["ok"],
            "note": row.get("error") or "", "prompt_tokens": row.get("prompt_tokens"),
            "ttft_s": row.get("ttft_s"), "prefill_tok_s": row.get("prefill_tok_s"),
            "decode_tok_s": row.get("decode_tok_s"), "elapsed_s": row.get("elapsed_s"),
            "error": result.get("error"), "plan_before": plan,
            "details": {"window": row.get("window"), "target_gb": row.get("target_gb"),
                        "requested_tokens": row.get("requested_tokens")}}
    try:
        path = os.path.join(HOME, "metrics", "exerciser.jsonl")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a") as f:
            f.write(json.dumps(line) + "\n")
    except OSError:
        pass


def set_env(key, value):
    """Persist a setting in ctl.env, which every script and the app read."""
    path = os.path.join(HOME, "ctl.env")
    lines = []
    if os.path.exists(path):
        lines = [l for l in open(path).read().splitlines() if not l.startswith(key + "=")]
    if value is not None:
        lines.append(f"{key}={value}")
    with open(path + ".tmp", "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(path + ".tmp", path)
    if value is None:
        os.environ.pop(key, None)
    else:
        os.environ[key] = str(value)


def server_refusal():
    """What the server actually said when it declined to start."""
    log = os.path.join(HOME, "slotstream.log")
    try:
        with open(log, errors="replace") as f:
            f.seek(max(0, os.path.getsize(log) - 20_000))
            lines = [l.strip() for l in f if "Error:" in l or "insufficient" in l]
    except OSError:
        return None
    return lines[-1].replace("Error: ", "")[:200] if lines else None


# What we give up, in order, to make a window work. Least sacrifice first: the window is
# what the user gets, so retention and pass size go before it does. See CONSTRAINTS.md.
LADDER = [
    {"retention": "full", "chunk": None, "gives_up": "nothing"},
    {"retention": "32768", "chunk": None, "gives_up": "keeping only 32,768 tokens of conversation"},
    {"retention": None, "chunk": None, "gives_up": "the server's own small retention"},
    {"retention": "32768", "chunk": "512", "gives_up": "a 512-token prefill pass"},
    {"retention": None, "chunk": "512", "gives_up": "a 512-token pass and little retention"},
    {"retention": None, "chunk": "256", "gives_up": "a 256-token pass, the smallest we run"},
]


def restart(window, target_gb, retention=None, chunk=None):
    """Bring the server up at one configuration. False when it will not start there.

    `retention` is how much conversation the server may keep: "full", a token count,
    or None for the server's own default. It is a dimension of the search, not a
    setting we inherit: a large window with a full conversation reserved can fail to
    start where the same window with less retention runs fine."""
    set_env("SLOTSTREAM_MEMORY_GB", f"{target_gb:.1f}" if target_gb else None)
    set_env("SLOTSTREAM_PREFIX_CACHE_TOKENS", retention)
    set_env("SLOTSTREAM_PREFILL_CHUNK", chunk)
    LAST_GOOD["dirty"] = True
    out = ctl("restart", str(window))
    if out.returncode == 0:
        LAST_GOOD["config"] = (window, target_gb, retention, chunk)
        log_attempt(kind="start", window=window, target_gb=target_gb, chunk=chunk or "default",
                    retention=retention or "default", ok=True, reason="server started")
        return True
    why = server_refusal() or (out.stderr or out.stdout).strip().splitlines()[-1][:160]
    print(f"    would not start at {target_gb:.1f} GB / {window:,} "
          f"(keeping {retention or 'the default'}): {why}", flush=True)
    RESTART_REASON["why"] = why
    log_attempt(kind="start", window=window, target_gb=target_gb, chunk=chunk or "default",
                retention=retention or "default", ok=False, reason=why)
    return False


RESTART_REASON = {"why": None}


def critical_pressure():
    level = subprocess.run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"],
                           capture_output=True, text=True).stdout.strip()
    return level == "4"


def probe(exerciser, window, size, target, rows, retention=None):
    """One prompt at this configuration, recorded in the progress file as it goes."""
    progress(window=window, size=size, target_gb=round(target, 1),
             phase="sending a prompt of this size")
    row = measure(exerciser, size, f"calibrate-{window}")
    row["window"], row["target_gb"] = window, round(target, 1)
    row["critical_pressure"] = critical_pressure()
    rows.append(row)
    log_probe(row, retention)
    progress(rows=[{"window": r["window"], "size": r["size"], "ok": r["ok"],
                    "ttft_s": r.get("ttft_s"), "error": r.get("error"),
                    "target_gb": r.get("target_gb")} for r in rows],
             size=None, phase="between sizes")
    print(("ok " + (f"{row['ttft_s']:.0f} s to first token" if row["ttft_s"] else ""))
          if row["ok"] else f"failed ({row['error']})", flush=True)
    return row


def targets_to_try(ram, working_set, args):
    """Total-memory targets, most generous first.

    The machine decides this, not the model: an explicit --memory-gb goes past auto's
    own ceiling, so a large machine is measured at what it really has."""
    if args.memory_gb:
        return [args.memory_gb]
    # Do not pre-decide what the machine can spare. Start near all of it and let the
    # server's own refusal say where the ceiling is: that refusal is the measurement.
    # The Metal working set is a bound the planner applies itself, and a target above it
    # is worth trying precisely because nobody here should guess it.
    top = ram * 0.95
    out = []
    value = top
    while value >= MIN_TARGET_GB:
        out.append(round(value, 1))
        value -= max(2.0, top * 0.12)
    return out or [MIN_TARGET_GB]


def run(args):
    """Search the configuration space: how much memory, how big a window, in that order.

    Every configuration it tries is a real server start, so it always leaves the machine
    serving: whatever happens, the last configuration known to work is restored."""
    try:
        return search(args)
    finally:
        good = LAST_GOOD.get("config")
        if good and LAST_GOOD.get("dirty"):
            print(f"restoring the last working configuration: {good[0]:,} at "
                  + (f"{good[1]:.1f} GB" if good[1] else "auto"), flush=True)
            restart(*good)
            ctl("profile", str(good[0]))


LAST_GOOD = {"config": None, "dirty": False}


def search(args):
    exerciser = load("exerciser")
    ram, working_set = (args.ram, args.ram * 0.75) if args.ram else _machine()
    # Try past the qualified envelope too: with the window patch the server accepts it and
    # the planner refuses what does not fit, so the machine decides rather than a constant.
    windows = [args.window] if args.window else [262_144, 196_608, 131_072, 98_304, 65_536, 49_152, 32_768, 16_384]
    fractions = (0.25, 0.5, 0.75) if args.quick else (0.25, 0.5, 0.75, 0.9)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    rows, notes = [], []
    progress(started=started, windows=windows, rows=[], attempts=[], phase="starting",
             window=None, size=None, target_gb=None)   # a fresh run shows nothing stale

    # 1. How much of this machine can the server actually use? Take the most generous
    #    target that serves a middling prompt without a memory failure or critical pressure.
    reference_window = min(32_768, max(windows))
    # How much conversation to keep, most generous first. A window that will not start
    # with the whole conversation kept often starts with less, and keeping less costs
    # one re-prefill rather than the window itself.
    retentions = ["full", "32768", None]
    target = None
    for candidate in targets_to_try(ram, working_set, args):
        print(f"\n=== trying a {candidate:.1f} GB memory target", flush=True)
        progress(phase=f"trying a {candidate:.1f} GB memory target", target_gb=candidate,
                 window=reference_window, size=None)
        if not restart(reference_window, candidate, retentions[0]):
            notes.append(f"{candidate:.1f} GB: server would not start")
            note_attempt(kind="memory target", target_gb=candidate, window=reference_window,
                         result="too much for this machine: the server would not start")
            continue
        print(f"  {int(reference_window * 0.5):,} tokens…", end=" ", flush=True)
        row = probe(exerciser, reference_window, int(reference_window * 0.5) // 1000 * 1000, candidate,
                    rows, retentions[0])
        if row["ok"] and not row["critical_pressure"]:
            target = candidate
            note_attempt(kind="memory target", target_gb=candidate, window=reference_window,
                         result=f"works: {row['ttft_s']:.0f} s to first token" if row.get("ttft_s") else "works")
            print(f"  {candidate:.1f} GB works", flush=True)
            break
        reason = row.get("error") or "the machine went to critical pressure"
        notes.append(f"{candidate:.1f} GB: {reason}")
        note_attempt(kind="memory target", target_gb=candidate, window=reference_window, result=reason)
    if target is None:
        print("no memory target served a prompt; is the server healthy?", file=sys.stderr)
        progress(phase="no memory target worked")
        return 1

    # 2. How large a window does that target carry? Accept the largest window whose
    #    prompts work up to three quarters of itself.
    chosen_window, window_rows, chosen_retention = None, [], retentions[0]
    for window in windows:
        if window <= reference_window and any(r["ok"] and r["window"] == reference_window for r in rows) \
           and window != reference_window:
            pass
        print(f"\n=== window {window:,} at {target:.1f} GB", flush=True)
        progress(phase="testing this window", window=window, target_gb=target, size=None)
        # Walk the ladder: give up the cheapest thing first, and only reject the window
        # when there is nothing left to give up.
        rung = None
        for candidate in LADDER:
            if restart(window, target, candidate["retention"], candidate["chunk"]):
                rung = candidate
                break
            note_attempt(kind="window", window=window, target_gb=target,
                         result=f"giving up {candidate['gives_up']}: " + (RESTART_REASON["why"] or "would not start"))
        if rung is None:
            notes.append(f"window {window:,}: nothing left to give up at {target:.1f} GB")
            continue
        started_here = rung["retention"]
        if rung is not LADDER[0]:
            print(f"  started by giving up {rung['gives_up']}", flush=True)
        here = []
        for fraction in fractions:
            size = int(window * fraction) // 1000 * 1000
            print(f"  {size:,} tokens…", end=" ", flush=True)
            row = probe(exerciser, window, size, target, rows, started_here)
            here.append(row)
            if not row["ok"] and row["error"] == "insufficient_memory":
                # The prompt, not the plan, ran out of memory. Step down the ladder and
                # try the same size again before giving up on this window.
                retried = False
                for candidate in LADDER[LADDER.index(rung) + 1:]:
                    print(f"  giving up {candidate['gives_up']} and retrying {size:,}…",
                          end=" ", flush=True)
                    if not restart(window, target, candidate["retention"], candidate["chunk"]):
                        continue
                    rung, started_here = candidate, candidate["retention"]
                    row = probe(exerciser, window, size, target, rows, started_here)
                    here.append(row)
                    retried = True
                    if row["ok"]:
                        break
                if not row["ok"]:
                    break
                if retried:
                    continue
        good = [r for r in here if r["ok"] and r.get("prompt_tokens")]
        largest_here = max((r["prompt_tokens"] for r in good), default=0)
        note_attempt(kind="window", window=window, target_gb=target,
                     result=(f"carried {largest_here:,} tokens" if largest_here else "carried nothing")
                            + (" — accepted" if largest_here >= window * 0.7 else ""))
        if good and largest_here >= window * 0.7:
            chosen_window, window_rows, chosen_retention = window, here, started_here
            break
        notes.append(f"window {window:,}: carried only "
                     + (f"{max((r['prompt_tokens'] or 0) for r in good):,} tokens" if good else "nothing"))
        if not chosen_window and good:
            # keep the best so far, and keep looking lower
            chosen_window, window_rows, chosen_retention = window, here, started_here

    if chosen_window is None:
        print("no window carried a prompt at that target", file=sys.stderr)
        progress(phase="no window carried a prompt")
        return 1

    # 3. Settle there and keep it: the window in the profile, the target in ctl.env.
    print(f"\n=== settling on {chosen_window:,} at {target:.1f} GB", flush=True)
    restart(chosen_window, target, chosen_retention)
    ctl("profile", str(chosen_window))
    # The measured target supersedes any share we picked by hand earlier.
    set_env("SLOTSTREAM_MAX_RAM_PERCENT", None)
    LAST_GOOD["dirty"] = False

    good = [r for r in window_rows if r["ok"] and r.get("prompt_tokens")]
    failed = [r for r in window_rows if not r["ok"]]
    largest = max((r["prompt_tokens"] for r in good), default=0)
    ttft = sorted(r["ttft_s"] for r in good if r["ttft_s"])
    decode = sorted(r["decode_tok_s"] for r in good if r["decode_tok_s"])
    prefill = sorted(r["prefill_tok_s"] for r in good if r["prefill_tok_s"])
    result = {
        "measured_at": started, "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "window": chosen_window,
        "memory_target_gb": target,
        "retention": chosen_retention or "the server's default",
        "prefill_chunk": os.environ.get("SLOTSTREAM_PREFILL_CHUNK", "default"),
        "largest_prompt_ok": largest,
        "comfortable_prompt": int(largest * 0.8) // 1000 * 1000,
        "first_failure_at": min([r["requested_tokens"] for r in failed], default=None),
        "ttft_median_s": ttft[len(ttft) // 2] if ttft else None,
        "ttft_at_largest_s": max(good, key=lambda r: r["prompt_tokens"])["ttft_s"] if good else None,
        "prefill_median_tok_s": prefill[len(prefill) // 2] if prefill else None,
        "decode_median_tok_s": decode[len(decode) // 2] if decode else None,
        "rows": rows, "notes": notes,
        "machine": _machine_description(),
        "ram_percent": os.environ.get("SLOTSTREAM_MAX_RAM_PERCENT", "70"),
    }
    result["headline"] = (
        f"up to {result['comfortable_prompt']:,}-token prompts at a {result['window']:,} window"
        + (f", about {result['ttft_median_s']:.0f} s to the first token" if result["ttft_median_s"] else "")
        + (f", {result['decode_median_tok_s']:.1f} tok/s generating" if result["decode_median_tok_s"] else ""))
    if chosen_window >= 65_536:
        result["limited_by"] = "the server's 65,536-token limit — the next gain has to come from Slotstream"
    elif failed:
        result["limited_by"] = f"memory during long prefills, at a {target:.1f} GB target"
    else:
        result["limited_by"] = "the sizes tested"
    os.makedirs(HOME, exist_ok=True)
    tmp = RESULT + ".tmp"
    with open(tmp, "w") as f:
        json.dump(result, f, indent=2)
    os.replace(tmp, RESULT)
    clear_progress()
    show(result)
    return 0


def _machine():
    """RAM and the Metal working set. The server reports the real working set; the
    three-quarters estimate is only a fallback for when it is not running."""
    try:
        ram = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True,
                                 timeout=5).stdout.strip()) / 1e9
    except (OSError, ValueError, subprocess.SubprocessError):
        ram = 16.0
    working_set = None
    import urllib.request
    try:
        req = urllib.request.Request(
            f"http://127.0.0.1:{os.environ.get('SLOTSTREAM_PORT', '11434')}/api/show",
            data=json.dumps({"name": os.environ.get("SLOTSTREAM_MODEL", "qwen3.8-flash-next:4bit")}).encode(),
            headers={"Content-Type": "application/json"})
        plan = json.load(urllib.request.urlopen(req, timeout=10))["details"]["memory_plan"]
        working_set = plan.get("device_working_set_gb")
        ram = plan.get("device_ram_gb") or ram
    except Exception:
        pass
    return ram, working_set or ram * 0.75


def _machine_description():
    ram, _ = _machine()
    chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True,
                          text=True).stdout.strip()
    return f"{ram:.0f} GB {chip}".strip()


def _ceiling(ram, working_set, percent):
    """The largest window whose plan fits, from the same ledger window-budget.py uses."""
    u = 27_648 / 1e9
    target = min(33.0, percent / 100 * ram, working_set - 2.0)
    room = target - 1.00 - 5.30 - 1.33 - 0.34 - 1.77
    return int(max(0, min((room / u + 3 * 32_768) / 4 if room > 0 else 0, 65_536)))


def live():
    """What the running measurement has tried and found, for the terminal."""
    if not os.path.exists(PROGRESS):
        running = subprocess.run(["pgrep", "-f", "calibrate.py"], capture_output=True, text=True).stdout.split()
        print("no measurement in progress" + (" (one is starting)" if len(running) > 1 else ""))
        return show()
    with open(PROGRESS) as f:
        p = json.load(f)
    print(f"measuring since {p.get('started', '?')}, updated {p.get('updated', '?')}")
    if p.get("target_gb") or p.get("window"):
        print(f"  now: {p.get('phase', '')}"
              + (f" — {p['window']:,} window" if p.get("window") else "")
              + (f" at {p['target_gb']:.1f} GB" if p.get("target_gb") else "")
              + (f", {p['size']:,} tokens" if p.get("size") else ""))
    for a in p.get("attempts", []):
        what = (f"{a['target_gb']:.1f} GB target" if a["kind"] == "memory target"
                else f"{a['window']:,} window at {a['target_gb']:.1f} GB")
        print(f"  tried {what}: {a['result']}")
    for r in p.get("rows", []):
        mark = "ok  " if r["ok"] else "FAIL"
        detail = (f"{r['ttft_s']:.0f} s to first token" if r.get("ttft_s") else (r.get("error") or ""))
        print(f"  {mark} {r['window']:,} window, {r['size']:,} tokens: {detail}")
    return 0


def show(result=None):
    if result is None:
        if not os.path.exists(RESULT):
            print("no calibration yet: run scripts/calibrate.py")
            return 1
        with open(RESULT) as f:
            result = json.load(f)
    print("\n" + "=" * 72)
    print(f"  {result['headline']}")
    print("=" * 72)
    print(f"  machine:        {result.get('machine', '?')}")
    print(f"  window:         {result['window']:,} tokens"
          + (f" at a {result['memory_target_gb']:.1f} GB memory target" if result.get("memory_target_gb") else ""))
    if result.get("retention"):
        print(f"  keeping:        {result['retention']} of the conversation between turns")
    print(f"  largest prompt: {result['largest_prompt_ok']:,} answered"
          + (f"; {result['first_failure_at']:,} failed" if result.get("first_failure_at") else ""))
    if result.get("ttft_at_largest_s"):
        print(f"  at that size:   {result['ttft_at_largest_s']:.0f} s to the first token")
    if result.get("prefill_median_tok_s"):
        print(f"  rates:          {result['prefill_median_tok_s']:.0f} tok/s reading, "
              f"{result.get('decode_median_tok_s') or 0:.1f} tok/s generating")
    print(f"  measured:       {result['measured_at']}")
    if result.get("limited_by"):
        print(f"  limited by:     {result['limited_by']}")
    ok, why = current(result)
    if not ok:
        print(f"  out of date:    {why}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--window", type=int)
    # The cap the server will actually use, so the windows we try are ones it can plan.
    ap.add_argument("--percent", type=float,
                    default=float(os.environ.get("SLOTSTREAM_MAX_RAM_PERCENT", "70")))
    ap.add_argument("--ram", type=float)
    ap.add_argument("--memory-gb", type=float, dest="memory_gb",
                    help="skip the memory search and measure at this total target")
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--progress", action="store_true",
                    help="what the measurement running right now has found so far")
    ap.add_argument("--auto", action="store_true",
                    help="run on its own when the answer is missing or stale and you are away")
    ap.add_argument("--force", action="store_true", help="calibrate even while OpenCode is active")
    a = ap.parse_args()
    if a.show:
        return show()
    if a.progress:
        return live()
    if a.auto:
        return auto(a)
    why = busy()
    if why and not a.force:
        print(why + " — run it when you are done, or pass --force", file=sys.stderr)
        return 2
    return run(a)


if __name__ == "__main__":
    sys.exit(main())
