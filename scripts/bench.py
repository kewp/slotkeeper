#!/usr/bin/env python3
"""Benchmark the local Slotstream server through its OpenAI-compatible streaming endpoint.

Measures time to first token, decode rate, end-to-end rate and reported token usage,
and snapshots the plan/prefix-cache state around each request. Appends one JSON line
per request to ~/.slotstream/metrics/bench.jsonl so runs on different profiles can be
compared later.

Usage:
  bench.py                       run the "short" and "medium" prompts once
  bench.py --set short           one prompt set
  bench.py --set long            ~8K-token prompt; expect minutes of prefill at the current plan
  bench.py --repeat 2            repeat each prompt (second pass shows prefix-cache reuse)
  bench.py --label 32k-everyday  tag the rows for later comparison
  bench.py --prompt-file f.txt   use your own prompt text

The server runs requests one at a time. Do not benchmark while OpenCode is mid-request.
"""
import argparse, json, os, sys, time, urllib.request, urllib.error
from datetime import datetime, timezone

HOME = os.environ.get("SLOTSTREAM_HOME", os.path.expanduser("~/.slotstream"))
_env_file = os.path.join(HOME, "ctl.env")
if os.path.exists(_env_file):
    for _line in open(_env_file):
        if "=" in _line and not _line.startswith("#"):
            _k, _v = _line.rstrip("\n").split("=", 1)
            os.environ.setdefault(_k.strip(), _v.strip())
PORT = os.environ.get("SLOTSTREAM_PORT", "11434")
MODEL = os.environ.get("SLOTSTREAM_MODEL", "qwen3.8-flash-next:4bit")
BASE = f"http://127.0.0.1:{PORT}"
OUT = os.path.join(HOME, "metrics", "bench.jsonl")

FILLER = (
    "The elastic expert cache grows when memory is free and shrinks when other applications need it. "
    "Prefill reads the prompt in fixed chunks, and follow-up turns re-read only what is new. "
)

PROMPT_SETS = {
    "short": [("hello", "Reply with one short sentence: what is a prefix cache?", 64)],
    "medium": [(
        "review",
        "Review the following TypeScript function for bugs and suggest improvements. Be concise.\n\n"
        + open(os.path.join(os.path.dirname(__file__), "..", "model-stats.ts")).read()[:6000],
        400,
    )],
    "long": [(
        "long-summary",
        "Summarize the recurring themes in the following notes in five bullet points.\n\n" + FILLER * 220,
        300,
    )],
}


def get_json(path, body=None, timeout=3):
    req = urllib.request.Request(BASE + path, method="POST" if body else "GET")
    data = None
    if body is not None:
        req.add_header("content-type", "application/json")
        data = json.dumps(body).encode()
    try:
        with urllib.request.urlopen(req, data, timeout=timeout) as r:
            return json.load(r)
    except Exception:
        return None


def snapshot():
    show = get_json("/api/show", {"model": MODEL}) or {}
    details = show.get("details", {})
    plan = details.get("memory_plan", {})
    cache = details.get("prefix_cache", {})
    return {
        "experts_per_layer": plan.get("experts_per_layer_cached"),
        "pool_gb": plan.get("pool_gb"),
        "max_context": plan.get("max_context_tokens"),
        "est_prefill_tok_s": plan.get("est_prefill_tok_s"),
        "est_warm_tok_s": plan.get("est_warm_tok_s"),
        "prefix_held_tokens": cache.get("held_tokens"),
        "prefix_hits": cache.get("hits"),
        "prefix_misses": cache.get("misses"),
    }


def run_one(name, prompt, max_tokens, label):
    body = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "stream": True,
        "stream_options": {"include_usage": True},
        "temperature": 0,
    }
    before = snapshot()
    req = urllib.request.Request(BASE + "/v1/chat/completions", json.dumps(body).encode(), {"content-type": "application/json"})
    started = time.monotonic()
    first = None
    chunks = 0
    text = []
    usage = None
    finish = None
    error = None
    try:
        with urllib.request.urlopen(req, timeout=3600) as r:
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    event = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                if event.get("error"):
                    error = event["error"]
                    break
                if event.get("usage"):
                    usage = event["usage"]
                for choice in event.get("choices", []):
                    delta = choice.get("delta", {})
                    piece = delta.get("content") or delta.get("reasoning_content") or ""
                    if piece:
                        if first is None:
                            first = time.monotonic()
                        chunks += 1
                        text.append(piece)
                    if choice.get("finish_reason"):
                        finish = choice["finish_reason"]
    except urllib.error.HTTPError as e:
        error = {"status": e.code, "body": e.read().decode("utf-8", "replace")[:500]}
    except Exception as e:  # noqa: BLE001
        error = {"exception": repr(e)}
    ended = time.monotonic()
    after = snapshot()

    out_tokens = (usage or {}).get("completion_tokens") or chunks
    prompt_tokens = (usage or {}).get("prompt_tokens")
    ttft = (first - started) if first else None
    decode_s = (ended - first) if first else None
    row = {
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "label": label,
        "prompt": name,
        "prompt_chars": len(prompt),
        "prompt_tokens": prompt_tokens,
        "output_tokens": out_tokens,
        "ttft_s": round(ttft, 2) if ttft else None,
        "prefill_tok_s": round(prompt_tokens / ttft, 1) if (prompt_tokens and ttft) else None,
        "decode_tok_s": round(out_tokens / decode_s, 2) if (decode_s and out_tokens) else None,
        "end_to_end_tok_s": round(out_tokens / (ended - started), 2) if out_tokens else None,
        "total_s": round(ended - started, 2),
        "finish": finish,
        "error": error,
        "before": before,
        "after": after,
    }
    return row, "".join(text)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--set", action="append", choices=sorted(PROMPT_SETS), help="prompt set (repeatable)")
    ap.add_argument("--prompt-file", help="use this file's text as the prompt")
    ap.add_argument("--max-tokens", type=int, default=300)
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--label", default="")
    ap.add_argument("--show-output", action="store_true")
    args = ap.parse_args()

    if not get_json("/api/version"):
        sys.exit(f"server not reachable at {BASE}")

    if args.prompt_file:
        prompts = [(os.path.basename(args.prompt_file), open(args.prompt_file).read(), args.max_tokens)]
    else:
        prompts = [p for s in (args.set or ["short", "medium"]) for p in PROMPT_SETS[s]]

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    for name, prompt, max_tokens in prompts:
        for i in range(args.repeat):
            print(f"-> {name} pass {i + 1}/{args.repeat} ({len(prompt)} chars) ...", flush=True)
            row, text = run_one(name, prompt, max_tokens, args.label)
            with open(OUT, "a") as f:
                f.write(json.dumps(row) + "\n")
            if row["error"]:
                print(f"   error: {json.dumps(row['error'])[:300]}")
            else:
                print(
                    f"   prompt {row['prompt_tokens']} tok | TTFT {row['ttft_s']}s | prefill {row['prefill_tok_s']} tok/s | "
                    f"decode {row['decode_tok_s']} tok/s | out {row['output_tokens']} tok | total {row['total_s']}s | finish {row['finish']}"
                )
                print(f"   experts/layer {row['before']['experts_per_layer']} -> {row['after']['experts_per_layer']} | prefix held {row['after']['prefix_held_tokens']} | hits {row['after']['prefix_hits']} misses {row['after']['prefix_misses']}")
            if args.show_output:
                print("   ---\n" + text.strip()[:2000] + "\n   ---")
    print(f"rows appended to {OUT}")


if __name__ == "__main__":
    main()
