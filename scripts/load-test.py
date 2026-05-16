#!/usr/bin/env python3
"""Corporate AI gateway load tester.

Lightweight stdlib-only load tester for OpenAI/Anthropic/LiteLLM-compatible
gateways. Measures latency percentiles, error rate, token throughput, and
requests/second under controlled concurrency or burst mode.

Usage:
  python3 scripts/load-test.py --url <gateway> --token "$TOK" \\
      --backend litellm [--concurrency 5] [--total 50] [--model gpt-5]
  python3 scripts/load-test.py --url <gateway> --token "$TOK" --burst 20

Exit codes:
  0  completed (even if some requests failed)
  2  authentication failure on warmup
  3  network unreachable
  5  malformed CLI args
"""
from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

Backend = str  # anthropic|openai|azure|litellm|bedrock-proxy|vertex

DEFAULT_PROMPT = 'Say "OK" only.'
SAFETY_THRESHOLD = 100  # require --yes above this

BACKEND_HINTS = {
    "anthropic": ("anthropic",),
    "azure": ("azure", "openai.azure.com"),
    "vertex": ("aiplatform.googleapis.com", "vertex"),
    "litellm": ("litellm",),
    "bedrock-proxy": ("bedrock",),
    "openai": ("openai.com", "api.openai"),
}


def detect_backend(url: str) -> Backend:
    host = urllib.parse.urlparse(url).netloc.lower()
    for backend, hints in BACKEND_HINTS.items():
        if any(h in host for h in hints):
            return backend
    return "openai"


def auth_headers(backend: Backend, token: str) -> dict[str, str]:
    base = {
        "User-Agent": "corporate-launcher-loadtest/1.0",
        "Content-Type": "application/json",
    }
    if backend == "anthropic":
        base["x-api-key"] = token
        base["anthropic-version"] = "2023-06-01"
    elif backend == "azure":
        base["api-key"] = token
    else:
        base["Authorization"] = f"Bearer {token}"
    return base


def completion_path(backend: Backend) -> str:
    if backend == "anthropic":
        return "/v1/messages"
    if backend == "azure":
        # Azure uses deployment-scoped paths; user must pass full URL or model=deployment
        return "/openai/deployments/{model}/chat/completions?api-version=2024-02-01"
    return "/v1/chat/completions"


def build_payload(backend: Backend, model: str, prompt: str) -> dict[str, Any]:
    if backend == "anthropic":
        return {
            "model": model,
            "max_tokens": 16,
            "messages": [{"role": "user", "content": prompt}],
        }
    return {
        "model": model,
        "max_tokens": 16,
        "messages": [{"role": "user", "content": prompt}],
    }


def extract_tokens(backend: Backend, body: bytes) -> int:
    try:
        data = json.loads(body.decode("utf-8", errors="replace"))
    except (ValueError, AttributeError):
        return 0
    if backend == "anthropic":
        usage = data.get("usage") or {}
        return int(usage.get("input_tokens", 0)) + int(usage.get("output_tokens", 0))
    usage = data.get("usage") or {}
    return int(usage.get("total_tokens", 0))


def build_ssl_context() -> ssl.SSLContext:
    ca = os.environ.get("REQUESTS_CA_BUNDLE") or os.environ.get("SSL_CERT_FILE")
    if ca and os.path.exists(ca):
        return ssl.create_default_context(cafile=ca)
    return ssl.create_default_context()


def build_opener(ctx: ssl.SSLContext) -> urllib.request.OpenerDirector:
    handlers: list[urllib.request.BaseHandler] = [
        urllib.request.HTTPSHandler(context=ctx),
    ]
    proxy = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
    if proxy:
        handlers.append(urllib.request.ProxyHandler({"https": proxy, "http": proxy}))
    return urllib.request.build_opener(*handlers)


def fire_one(
    opener: urllib.request.OpenerDirector,
    full_url: str,
    headers: dict[str, str],
    payload: bytes,
    backend: Backend,
    timeout: float,
) -> dict[str, Any]:
    req = urllib.request.Request(full_url, data=payload, headers=headers, method="POST")
    start = time.monotonic()
    try:
        resp = opener.open(req, timeout=timeout)
        body = resp.read()
        elapsed_ms = (time.monotonic() - start) * 1000
        return {
            "ok": True,
            "status": resp.status,
            "latency_ms": elapsed_ms,
            "tokens": extract_tokens(backend, body),
        }
    except urllib.error.HTTPError as e:
        elapsed_ms = (time.monotonic() - start) * 1000
        return {
            "ok": False,
            "status": e.code,
            "latency_ms": elapsed_ms,
            "tokens": 0,
        }
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        elapsed_ms = (time.monotonic() - start) * 1000
        return {
            "ok": False,
            "status": 0,
            "latency_ms": elapsed_ms,
            "tokens": 0,
            "error": str(e)[:120],
        }


def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    k = (len(s) - 1) * (p / 100.0)
    lo = int(k)
    hi = min(lo + 1, len(s) - 1)
    frac = k - lo
    return s[lo] + (s[hi] - s[lo]) * frac


def build_full_url(base: str, backend: Backend, model: str) -> str:
    base = base.rstrip("/")
    path = completion_path(backend)
    if "{model}" in path:
        path = path.replace("{model}", urllib.parse.quote(model, safe=""))
    if base.endswith(path.split("?", 1)[0]):
        return base
    return base + path


def run_load(
    url: str,
    token: str,
    backend: Backend,
    model: str,
    prompt: str,
    total: int,
    concurrency: int,
    timeout: float,
    burst: bool,
) -> dict[str, Any]:
    ctx = build_ssl_context()
    opener = build_opener(ctx)
    headers = auth_headers(backend, token)
    full_url = build_full_url(url, backend, model)
    payload = json.dumps(build_payload(backend, model, prompt)).encode("utf-8")

    workers = total if burst else max(1, concurrency)
    results: list[dict[str, Any]] = []
    wall_start = time.monotonic()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [
            pool.submit(fire_one, opener, full_url, headers, payload, backend, timeout)
            for _ in range(total)
        ]
        for fut in as_completed(futures):
            results.append(fut.result())
    wall_elapsed = time.monotonic() - wall_start

    ok = [r for r in results if r["ok"]]
    errors = [r for r in results if not r["ok"]]
    error_codes: dict[str, int] = {}
    for r in errors:
        key = str(r["status"]) if r["status"] else "network"
        error_codes[key] = error_codes.get(key, 0) + 1

    latencies = [r["latency_ms"] for r in ok]
    total_tokens = sum(r["tokens"] for r in ok)

    return {
        "url": full_url,
        "model": model,
        "backend": backend,
        "mode": "burst" if burst else "ramp",
        "concurrency": workers,
        "total": total,
        "completed": len(ok),
        "errors": len(errors),
        "error_codes": error_codes,
        "latency_ms": {
            "p50": round(percentile(latencies, 50), 1),
            "p95": round(percentile(latencies, 95), 1),
            "p99": round(percentile(latencies, 99), 1),
            "max": round(max(latencies), 1) if latencies else 0.0,
        },
        "wall_seconds": round(wall_elapsed, 3),
        "tokens_per_sec": round(total_tokens / wall_elapsed, 2) if wall_elapsed > 0 else 0.0,
        "req_per_sec": round(len(ok) / wall_elapsed, 2) if wall_elapsed > 0 else 0.0,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Corporate AI gateway load tester")
    parser.add_argument("--url", required=True, help="Gateway base URL")
    parser.add_argument("--token", required=True, help="API token")
    parser.add_argument(
        "--backend",
        choices=["auto", "anthropic", "openai", "azure", "litellm", "bedrock-proxy", "vertex"],
        default="auto",
    )
    parser.add_argument("--model", default="gpt-4o-mini", help="Model id (default: gpt-4o-mini)")
    parser.add_argument("--concurrency", type=int, default=5)
    parser.add_argument("--total", type=int, default=50)
    parser.add_argument("--burst", type=int, default=0, help="Fire N requests instantly (no throttle)")
    parser.add_argument("--prompt", default=DEFAULT_PROMPT)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--yes", action="store_true", help="Confirm runs above safety threshold")
    args = parser.parse_args()

    if args.burst > 0:
        total = args.burst
        burst_mode = True
    else:
        total = args.total
        burst_mode = False

    if total > SAFETY_THRESHOLD and not args.yes:
        print(
            json.dumps({
                "error": f"refusing to send {total} requests without --yes",
                "safety_threshold": SAFETY_THRESHOLD,
            }, indent=2),
            file=sys.stderr,
        )
        return 5

    if args.concurrency < 1 or total < 1:
        print(json.dumps({"error": "concurrency and total must be >= 1"}), file=sys.stderr)
        return 5

    backend = args.backend if args.backend != "auto" else detect_backend(args.url)

    try:
        report = run_load(
            url=args.url,
            token=args.token,
            backend=backend,
            model=args.model,
            prompt=args.prompt,
            total=total,
            concurrency=args.concurrency,
            timeout=args.timeout,
            burst=burst_mode,
        )
    except KeyboardInterrupt:
        print(json.dumps({"error": "interrupted"}), file=sys.stderr)
        return 130

    print(json.dumps(report, indent=2))

    if report["completed"] == 0:
        codes = report["error_codes"]
        if "401" in codes or "403" in codes:
            return 2
        if "network" in codes or "0" in codes:
            return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
