#!/usr/bin/env python3
"""Queue coding tasks for the local model and run them unattended.

A job is one `opencode run` in one repository. The runner takes jobs one at a time,
only when the machine is free (your own OpenCode session, battery, memory pressure and
the night window are all respected), records what each one cost, and leaves a report.

Files (under ~/.slotstream/jobs):
  queued/<id>.json    waiting            running/<id>.json  in progress
  done/<id>.json      finished, with the result     logs/<id>.log  full output
  jobs.pause          pause flag; contents = reason (same convention as the exerciser)

Usage:
  jobs.py add <repo> "<task>" [--label NAME] [--agent build] [--auto] [--session ID]
  jobs.py list [--all]            queued and running jobs (--all includes finished)
  jobs.py show <id>               one job with its result and the tail of its log
  jobs.py cancel <id>             remove a queued job
  jobs.py run [--once]            run jobs now, ignoring the night window
  jobs.py daemon                  run forever, waiting for the machine to be free
  jobs.py report [--hours N]      what finished, what it cost, what it changed

--auto passes OpenCode's --auto, which approves every tool call the model makes,
including shell commands. Unattended runs need it; only use it on a repository whose
working tree you are willing to have rewritten, and review the diff in the morning.

Settings (env or ~/.slotstream/ctl.env):
  SLOTSTREAM_PORT, SLOTSTREAM_MODEL       the local provider and model
  JOBS_PROVIDER (slotstream)              OpenCode provider id for --model
  JOBS_HOURS (0-7)                        when the daemon may start a job
  JOBS_IDLE_MIN (30)                      ...or after this long without keyboard/mouse input
  JOBS_TIMEOUT_H (6)                      give up on one job after this many hours
  JOBS_RETRIES (2)                        retries after a memory failure
"""
import argparse, json, os, re, signal, subprocess, sys, time
from datetime import datetime, timedelta, timezone

HOME = os.environ.get("SLOTSTREAM_HOME", os.path.expanduser("~/.slotstream"))
_env = os.path.join(HOME, "ctl.env")
if os.path.exists(_env):
    for _line in open(_env):
        if "=" in _line and not _line.startswith("#"):
            k, v = _line.rstrip("\n").split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())

PORT = os.environ.get("SLOTSTREAM_PORT", "11434")
MODEL = os.environ.get("SLOTSTREAM_MODEL", "qwen3.8-flash-next:4bit")
PROVIDER = os.environ.get("JOBS_PROVIDER", "slotstream")
HOURS = os.environ.get("JOBS_HOURS", "0-7")
IDLE_MIN = float(os.environ.get("JOBS_IDLE_MIN", "30"))
TIMEOUT_H = float(os.environ.get("JOBS_TIMEOUT_H", "6"))
RETRIES = int(os.environ.get("JOBS_RETRIES", "2"))
ROOT = os.path.join(HOME, "jobs")
QUEUED, RUNNING, DONE, LOGS = (os.path.join(ROOT, d) for d in ("queued", "running", "done", "logs"))
PAUSE = os.path.join(ROOT, "jobs.pause")
ACTIVE = os.path.join(HOME, "opencode-active")
OPENCODE_DB = os.environ.get("OPENCODE_DB", os.path.expanduser("~/.local/share/opencode/opencode.db"))

stop = False


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def sh(cmd, timeout=10):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=2)
    os.replace(tmp, path)


def jobs_in(folder):
    if not os.path.isdir(folder):
        return []
    out = []
    for name in sorted(os.listdir(folder)):
        if name.endswith(".json"):
            job = read_json(os.path.join(folder, name))
            if job:
                job["_path"] = os.path.join(folder, name)
                out.append(job)
    return out


def find(job_id):
    for folder in (QUEUED, RUNNING, DONE):
        for job in jobs_in(folder):
            if job_id in (job["id"], job["id"].split("-", 2)[-1]) or job["id"].startswith(job_id) or job["id"].endswith(job_id):
                return job
    return None


# ---------- when may a job run ----------

def user_idle_minutes():
    for line in sh(["ioreg", "-c", "IOHIDSystem", "-d", "4"]).splitlines():
        if '"HIDIdleTime"' in line:
            try:
                return int(line.rsplit("=", 1)[1].strip()) / 1e9 / 60
            except ValueError:
                return None
    return None


def in_hours():
    try:
        start, end = (int(x) for x in HOURS.split("-"))
    except ValueError:
        return True
    h = datetime.now().hour
    return start <= h < end if start <= end else (h >= start or h < end)


def server_ready():
    import urllib.request
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{PORT}/api/version", timeout=5).read()
        return True
    except Exception:
        return False


def blocked(respect_window=True):
    """Why a job may not start right now, or None."""
    if os.path.exists(PAUSE):
        return (open(PAUSE).read().strip() or "paused")
    if os.path.exists(ACTIVE):
        age = time.time() - os.path.getmtime(ACTIVE)
        if age < 600:
            info = read_json(ACTIVE) or {}
            return f"your OpenCode session is active ({info.get('agent', 'request')}, {int(age)}s ago)"
    batt = sh(["pmset", "-g", "batt"])
    if "discharging" in batt:
        return "on battery"
    level = sh(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"]).strip()
    if level == "4":
        return "memory pressure critical"
    if not server_ready():
        return "server not ready"
    if respect_window and not in_hours():
        idle = user_idle_minutes()
        if not (IDLE_MIN > 0 and idle is not None and idle >= IDLE_MIN):
            return f"outside the job window ({HOURS})" + (f" and you were active {idle:.0f} min ago" if idle is not None else "")
    return None


# ---------- running one job ----------

def git(repo, *args):
    return sh(["git", "-C", repo] + list(args), timeout=30).strip()


def run_job(job, respect_window=True):
    job["started"] = now()
    job["attempts"] = job.get("attempts", 0) + 1
    path = os.path.join(RUNNING, os.path.basename(job["_path"]))
    os.makedirs(RUNNING, exist_ok=True)
    os.replace(job["_path"], path)
    job["_path"] = path
    write_json(path, {k: v for k, v in job.items() if not k.startswith("_")})

    log_path = os.path.join(LOGS, job["id"] + ".log")
    os.makedirs(LOGS, exist_ok=True)
    cmd = ["opencode", "run", "--dir", job["repo"], "--model", f"{PROVIDER}/{MODEL}",
           "--agent", job.get("agent", "build"), "--print-logs", "--log-level", "INFO"]
    if job.get("auto"):
        cmd.append("--auto")
    if job.get("session"):
        cmd += ["--session", job["session"]]
    elif job.get("label"):
        cmd += ["--title", job["label"]]
    cmd.append(job["task"])

    before = {"head": git(job["repo"], "rev-parse", "--short", "HEAD"),
              "dirty": git(job["repo"], "status", "--porcelain")}
    t0 = time.monotonic()
    with open(log_path, "a") as log:
        log.write(f"\n=== {now()} attempt {job['attempts']}: {' '.join(cmd[:8])} ...\n")
        log.flush()
        try:
            proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
            deadline = time.monotonic() + TIMEOUT_H * 3600
            while proc.poll() is None:
                if stop:
                    proc.terminate()
                    break
                if time.monotonic() > deadline:
                    proc.terminate()
                    job["result"] = "timeout"
                    break
                time.sleep(5)
            code = proc.wait(timeout=60)
        except (OSError, subprocess.SubprocessError) as e:
            code, job["result"] = -1, f"could not run opencode: {e}"

    job["elapsed_s"] = round(time.monotonic() - t0, 1)
    job["exit_code"] = code
    job["finished"] = now()
    after = {"head": git(job["repo"], "rev-parse", "--short", "HEAD"),
             "dirty": git(job["repo"], "status", "--porcelain")}
    job["changed_files"] = len([l for l in after["dirty"].splitlines() if l not in before["dirty"].splitlines()])
    job["diff_stat"] = git(job["repo"], "diff", "--stat")[-1000:]
    job["commits"] = 0 if before["head"] == after["head"] else len(
        git(job["repo"], "log", "--oneline", f"{before['head']}..{after['head']}").splitlines())
    tail = ""
    try:
        with open(log_path) as f:
            tail = f.read()[-4000:]
    except OSError:
        pass
    memory_failure = "insufficient_memory" in tail
    if "result" not in job:
        job["result"] = "ok" if code == 0 else ("memory" if memory_failure else "failed")

    # A memory failure is worth retrying: the server keeps the prefix it had read,
    # so the next attempt resumes rather than re-reading the whole prompt.
    if job["result"] == "memory" and job["attempts"] <= RETRIES:
        job["result"] = "retrying"
        os.replace(path, os.path.join(QUEUED, os.path.basename(path)))
        job["_path"] = os.path.join(QUEUED, os.path.basename(path))
        write_json(job["_path"], {k: v for k, v in job.items() if not k.startswith("_")})
        return job
    os.makedirs(DONE, exist_ok=True)
    dest = os.path.join(DONE, os.path.basename(path))
    write_json(dest, {k: v for k, v in job.items() if not k.startswith("_")})
    os.remove(path)
    job["_path"] = dest
    return job


def run_loop(once=False, respect_window=True, daemon=False):
    while not stop:
        queued = jobs_in(QUEUED)
        if not queued:
            if once or not daemon:
                print("no queued jobs")
                return
            time.sleep(60)
            continue
        why = blocked(respect_window)
        if why:
            print(f"waiting: {why}", flush=True)
            if once and not daemon:
                return
            time.sleep(60)
            continue
        job = queued[0]
        print(f"running {job['id']}: {job['task'][:70]}", flush=True)
        job = run_job(job, respect_window)
        print(f"  {job['result']} in {job.get('elapsed_s', 0) / 60:.1f} min, "
              f"{job.get('changed_files', 0)} files changed, log {os.path.join(LOGS, job['id'] + '.log')}", flush=True)
        if once:
            return


# ---------- reporting ----------

def session_cost(job):
    """What the model spent on this job, from OpenCode's own database."""
    if not os.path.exists(OPENCODE_DB) or not job.get("started"):
        return {}
    import sqlite3
    try:
        db = sqlite3.connect(f"file:{OPENCODE_DB}?mode=ro", uri=True, timeout=5)
        start = datetime.fromisoformat(job["started"]).timestamp() * 1000
        end = (datetime.fromisoformat(job["finished"]).timestamp() * 1000
               if job.get("finished") else time.time() * 1000)
        rows = db.execute(
            """select json_extract(data,'$.tokens.input'), json_extract(data,'$.tokens.output'),
                      json_extract(data,'$.error') is not null
                 from message
                where time_created between ? and ? and json_extract(data,'$.providerID') = ?
                  and json_extract(data,'$.role') = 'assistant'
                  and json_extract(data,'$.path.cwd') = ?""",
            (start, end, PROVIDER, job["repo"])).fetchall()
    except sqlite3.Error:
        return {}
    return {"turns": len(rows), "prompt_tokens": sum(r[0] or 0 for r in rows),
            "output_tokens": sum(r[1] or 0 for r in rows), "errors": sum(1 for r in rows if r[2])}


def report(hours):
    since = datetime.now(timezone.utc) - timedelta(hours=hours)
    done = [j for j in jobs_in(DONE)
            if j.get("finished") and datetime.fromisoformat(j["finished"]) >= since]
    running, queued = jobs_in(RUNNING), jobs_in(QUEUED)
    print(f"jobs in the last {hours:g}h: {len(done)} finished, {len(running)} running, {len(queued)} queued")
    for job in done:
        cost = session_cost(job)
        mark = {"ok": "✓", "timeout": "⏱", "memory": "mem", "failed": "✗"}.get(job["result"], job["result"])
        print(f"  {mark} {job['id']} [{os.path.basename(job['repo'])}] {job['task'][:60]}")
        print(f"      {job.get('elapsed_s', 0) / 60:.1f} min, {job.get('attempts', 1)} attempt(s), "
              f"{cost.get('turns', 0)} turns, {cost.get('prompt_tokens', 0)} prompt / {cost.get('output_tokens', 0)} output tokens"
              + (f", {cost['errors']} request errors" if cost.get("errors") else ""))
        if job.get("changed_files") or job.get("commits"):
            print(f"      {job.get('changed_files', 0)} files changed, {job.get('commits', 0)} commits — review with: git -C {job['repo']} diff")
    for job in running:
        print(f"  … {job['id']} running since {job.get('started')}")
    for job in queued:
        print(f"  · {job['id']} queued: {job['task'][:60]}")


# ---------- cli ----------

def cmd_add(a):
    repo = os.path.abspath(os.path.expanduser(a.repo))
    if not os.path.isdir(repo):
        sys.exit(f"no such directory: {repo}")
    task = " ".join(a.task).strip()
    if not task:
        sys.exit("give the job a task")
    slug = re.sub(r"[^a-z0-9]+", "-", task.lower())[:40].strip("-")
    job_id = datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + (slug or "job")
    job = {"id": job_id, "created": now(), "repo": repo, "task": task,
           "agent": a.agent, "auto": a.auto, "label": a.label or task[:60],
           "session": a.session, "attempts": 0, "result": "queued"}
    write_json(os.path.join(QUEUED, job_id + ".json"), job)
    print(f"queued {job_id}")
    if not a.auto:
        print("  note: without --auto, OpenCode will stop at the first tool call that needs approval")
    why = blocked()
    print(f"  the runner will start it when it can (now: {why or 'ready'})")


def cmd_list(a):
    for folder, mark in ((RUNNING, "…"), (QUEUED, "·"), (DONE, "✓")):
        if folder is DONE and not a.all:
            continue
        for job in jobs_in(folder):
            print(f"{mark} {job['id']} [{os.path.basename(job['repo'])}] {job.get('result', '')} {job['task'][:60]}")


def cmd_show(a):
    job = find(a.id)
    if not job:
        sys.exit(f"no job matching {a.id}")
    print(json.dumps({k: v for k, v in job.items() if not k.startswith("_")}, indent=2))
    log = os.path.join(LOGS, job["id"] + ".log")
    if os.path.exists(log):
        print(f"\n--- tail of {log}")
        with open(log) as f:
            print(f.read()[-2000:])


def cmd_cancel(a):
    job = find(a.id)
    if not job:
        sys.exit(f"no job matching {a.id}")
    if QUEUED not in job["_path"]:
        sys.exit(f"{job['id']} is not queued (it is {job.get('result')})")
    os.remove(job["_path"])
    print(f"cancelled {job['id']}")


def main():
    global stop
    signal.signal(signal.SIGTERM, lambda *_: globals().__setitem__("stop", True))
    signal.signal(signal.SIGINT, lambda *_: globals().__setitem__("stop", True))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("add"); p.add_argument("repo"); p.add_argument("task", nargs="+")
    p.add_argument("--label"); p.add_argument("--agent", default="build")
    p.add_argument("--auto", action="store_true"); p.add_argument("--session")
    p.set_defaults(fn=cmd_add)
    p = sub.add_parser("list"); p.add_argument("--all", action="store_true"); p.set_defaults(fn=cmd_list)
    p = sub.add_parser("show"); p.add_argument("id"); p.set_defaults(fn=cmd_show)
    p = sub.add_parser("cancel"); p.add_argument("id"); p.set_defaults(fn=cmd_cancel)
    p = sub.add_parser("run"); p.add_argument("--once", action="store_true")
    p.set_defaults(fn=lambda a: run_loop(once=a.once, respect_window=False))
    p = sub.add_parser("daemon")
    p.set_defaults(fn=lambda a: run_loop(daemon=True, respect_window=True))
    p = sub.add_parser("report"); p.add_argument("--hours", type=float, default=24)
    p.set_defaults(fn=lambda a: report(a.hours))
    a = ap.parse_args()
    for d in (QUEUED, RUNNING, DONE, LOGS):
        os.makedirs(d, exist_ok=True)
    a.fn(a)


if __name__ == "__main__":
    main()
