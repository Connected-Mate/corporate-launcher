#!/usr/bin/env python3
"""Corporate AI gateway probe.

Verifies connectivity, auth, available models, and TLS posture before the
corporate-launcher skill generates an actual launcher. Stdlib only.

Exit codes:
  0  OK
  2  authentication failure (401/403)
  3  network unreachable / DNS / timeout
  4  TLS certificate error
  5  malformed URL or CLI args
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Any

Backend = str  # one of: anthropic|openai|azure|vertex|litellm|bedrock-proxy

BACKEND_HINTS = {
    "anthropic": ("anthropic",),
    "azure": ("azure", "openai.azure.com"),
    "vertex": ("aiplatform.googleapis.com", "vertex"),
    "litellm": ("litellm",),
    "bedrock-proxy": ("bedrock",),
    "openai": ("openai.com", "api.openai"),
}


def mask_token(tok: str) -> str:
    if not tok:
        return ""
    if len(tok) <= 8:
        return "***"
    return f"{tok[:4]}...{tok[-4:]}"


def detect_backend(url: str) -> Backend:
    host = urllib.parse.urlparse(url).netloc.lower()
    for backend, hints in BACKEND_HINTS.items():
        if any(h in host for h in hints):
            return backend
    return "openai"  # safe default: OpenAI-compatible


def auth_headers(backend: Backend, token: str) -> dict[str, str]:
    base = {"User-Agent": "corporate-launcher-probe/1.0"}
    if backend == "anthropic":
        base["x-api-key"] = token
        base["anthropic-version"] = "2023-06-01"
    elif backend == "azure":
        base["api-key"] = token
    else:
        base["Authorization"] = f"Bearer {token}"
    return base


def auth_label(backend: Backend) -> str:
    return {
        "anthropic": "x-api-key",
        "azure": "api-key-header",
    }.get(backend, "bearer-token")


def probe_path(backend: Backend) -> str:
    return {
        "anthropic": "/v1/models",
        "openai": "/v1/models",
        "litellm": "/v1/models",
        "bedrock-proxy": "/v1/models",
        "azure": "/openai/models?api-version=2024-02-01",
        "vertex": "/v1/models",
    }.get(backend, "/v1/models")


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


def tls_info(url: str, ctx: ssl.SSLContext) -> dict[str, Any]:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https":
        return {"scheme": parsed.scheme}
    host = parsed.hostname or ""
    port = parsed.port or 443
    try:
        with socket.create_connection((host, port), timeout=5) as raw:
            with ctx.wrap_socket(raw, server_hostname=host) as ssock:
                cert = ssock.getpeercert()
        issuer = dict(x[0] for x in cert.get("issuer", []))
        expires_raw = cert.get("notAfter", "")
        expires_iso = ""
        if expires_raw:
            try:
                dt = datetime.strptime(expires_raw, "%b %d %H:%M:%S %Y %Z")
                expires_iso = dt.replace(tzinfo=timezone.utc).isoformat()
            except ValueError:
                expires_iso = expires_raw
        return {
            "cert_issuer": issuer.get("organizationName") or issuer.get("commonName", ""),
            "expires": expires_iso,
            "subject_cn": dict(x[0] for x in cert.get("subject", [])).get("commonName", ""),
        }
    except ssl.SSLError as e:
        return {"error": f"ssl: {e}"}
    except (socket.gaierror, socket.timeout, OSError) as e:
        return {"error": f"socket: {e}"}


def http_request(
    opener: urllib.request.OpenerDirector,
    url: str,
    headers: dict[str, str],
    timeout: float,
    data: bytes | None = None,
    method: str | None = None,
) -> tuple[int, bytes, float]:
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    start = time.monotonic()
    try:
        resp = opener.open(req, timeout=timeout)
        body = resp.read()
        return resp.status, body, (time.monotonic() - start) * 1000
    except urllib.error.HTTPError as e:
        body = e.read() if hasattr(e, "read") else b""
        return e.code, body, (time.monotonic() - start) * 1000


def parse_models(backend: Backend, body: bytes) -> list[str]:
    try:
        payload = json.loads(body.decode("utf-8", errors="replace"))
    except json.JSONDecodeError:
        return []
    if isinstance(payload, dict):
        data = payload.get("data") or payload.get("models") or payload.get("value") or []
    else:
        data = payload
    out: list[str] = []
    for item in data if isinstance(data, list) else []:
        if isinstance(item, str):
            out.append(item)
        elif isinstance(item, dict):
            mid = item.get("id") or item.get("model") or item.get("name")
            if mid:
                out.append(str(mid))
    return out


def minimal_completion(
    opener: urllib.request.OpenerDirector,
    base: str,
    backend: Backend,
    headers: dict[str, str],
    model: str,
    timeout: float,
) -> tuple[int, float, str]:
    if backend == "anthropic":
        url = base.rstrip("/") + "/v1/messages"
        payload = {
            "model": model,
            "max_tokens": 4,
            "messages": [{"role": "user", "content": "ping"}],
        }
    else:
        url = base.rstrip("/") + "/v1/chat/completions"
        payload = {
            "model": model,
            "max_tokens": 4,
            "messages": [{"role": "user", "content": "ping"}],
        }
    h = dict(headers)
    h["Content-Type"] = "application/json"
    status, body, latency = http_request(
        opener, url, h, timeout, data=json.dumps(payload).encode("utf-8"), method="POST"
    )
    snippet = body[:200].decode("utf-8", errors="replace")
    return status, latency, snippet


def emit(report: dict[str, Any], code: int) -> None:
    json.dump(report, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    sys.exit(code)


def main() -> None:
    p = argparse.ArgumentParser(description="Probe a corporate AI gateway.")
    p.add_argument("--url", required=True, help="Base URL of the gateway")
    p.add_argument("--token", required=True, help="Auth token (never logged)")
    p.add_argument(
        "--backend",
        choices=["auto", "anthropic", "openai", "azure", "vertex", "litellm", "bedrock-proxy"],
        default="auto",
    )
    p.add_argument("--model", default="", help="Model id for fallback completion probe")
    p.add_argument("--timeout", type=float, default=10.0)
    args = p.parse_args()

    parsed = urllib.parse.urlparse(args.url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        emit({"ok": False, "error": "bad-url", "url": args.url}, 5)

    backend = args.backend if args.backend != "auto" else detect_backend(args.url)
    headers = auth_headers(backend, args.token)
    warnings: list[str] = []

    ctx = build_ssl_context()
    opener = build_opener(ctx)

    tls = tls_info(args.url, ctx) if parsed.scheme == "https" else {"scheme": "http"}
    if "error" in tls and tls["error"].startswith("ssl:"):
        emit(
            {
                "ok": False,
                "backend": backend,
                "url": args.url,
                "auth": auth_label(backend),
                "token_preview": mask_token(args.token),
                "tls": tls,
                "error": "tls-error",
            },
            4,
        )

    models_url = args.url.rstrip("/") + probe_path(backend)
    try:
        status, body, latency = http_request(opener, models_url, headers, args.timeout)
    except urllib.error.URLError as e:
        reason = str(e.reason) if hasattr(e, "reason") else str(e)
        is_tls = "certificate" in reason.lower() or "ssl" in reason.lower()
        emit(
            {
                "ok": False,
                "backend": backend,
                "url": args.url,
                "auth": auth_label(backend),
                "token_preview": mask_token(args.token),
                "tls": tls,
                "error": reason,
            },
            4 if is_tls else 3,
        )
    except (socket.timeout, TimeoutError):
        emit({"ok": False, "backend": backend, "url": args.url, "error": "timeout"}, 3)

    if status in (401, 403):
        emit(
            {
                "ok": False,
                "backend": backend,
                "url": args.url,
                "auth": auth_label(backend),
                "token_preview": mask_token(args.token),
                "latency_ms": round(latency, 1),
                "http_status": status,
                "tls": tls,
                "error": "auth-failed",
            },
            2,
        )

    models: list[str] = []
    used_fallback = False
    fallback_info: dict[str, Any] = {}

    if 200 <= status < 300:
        models = parse_models(backend, body)
        if not models:
            warnings.append("models endpoint returned no entries")
    else:
        warnings.append(f"models endpoint http {status}")
        if args.model:
            used_fallback = True
            try:
                fb_status, fb_latency, fb_snippet = minimal_completion(
                    opener, args.url, backend, headers, args.model, args.timeout
                )
                fallback_info = {
                    "http_status": fb_status,
                    "latency_ms": round(fb_latency, 1),
                    "snippet": fb_snippet,
                }
                if fb_status in (401, 403):
                    emit(
                        {
                            "ok": False,
                            "backend": backend,
                            "url": args.url,
                            "auth": auth_label(backend),
                            "token_preview": mask_token(args.token),
                            "tls": tls,
                            "fallback": fallback_info,
                            "error": "auth-failed",
                        },
                        2,
                    )
                if not (200 <= fb_status < 300):
                    warnings.append(f"fallback completion http {fb_status}")
            except urllib.error.URLError as e:
                warnings.append(f"fallback failed: {e}")

    if args.model and models and args.model not in models:
        warnings.append(f"model '{args.model}' not found in catalog")

    report: dict[str, Any] = {
        "ok": True,
        "backend": backend,
        "url": args.url,
        "auth": auth_label(backend),
        "token_preview": mask_token(args.token),
        "latency_ms": round(latency, 1),
        "http_status": status,
        "models_available": models,
        "tls": tls,
        "warnings": warnings,
        "proxy": bool(os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")),
        "ca_bundle": os.environ.get("REQUESTS_CA_BUNDLE", ""),
    }
    if used_fallback:
        report["fallback"] = fallback_info

    emit(report, 0)


if __name__ == "__main__":
    main()
