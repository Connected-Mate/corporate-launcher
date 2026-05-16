"""Pytest suite for ``scripts/api-probe.py``.

Covers the corporate AI gateway probe:

* ``detect_backend`` — host-based routing across the 6 supported backends
* ``auth_headers`` — per-backend header conventions (x-api-key, api-key, Bearer)
* ``parse_models`` — extraction from ``data``/``models``/``value`` shapes
* ``mask_token`` — never leaks the raw token
* ``main`` — exit codes 0/2/3/4/5 and the public JSON schema

All HTTP I/O is intercepted via ``monkeypatch`` on the script's opener so the
suite never touches the network. Uses stdlib pytest only (no plugins).
"""

from __future__ import annotations

import importlib.util
import io
import json
import socket
import ssl
import sys
import urllib.error
from pathlib import Path
from typing import Any

import pytest

# ---------------------------------------------------------------------------
# Load scripts/api-probe.py as a module (hyphen in filename blocks import).
# ---------------------------------------------------------------------------
PROJECT_ROOT = Path(__file__).resolve().parent.parent
PROBE_PY = PROJECT_ROOT / "scripts" / "api-probe.py"

_spec = importlib.util.spec_from_file_location("api_probe", PROBE_PY)
assert _spec is not None and _spec.loader is not None
probe = importlib.util.module_from_spec(_spec)
sys.modules["api_probe"] = probe
_spec.loader.exec_module(probe)


# ---------------------------------------------------------------------------
# Fake HTTP plumbing
# ---------------------------------------------------------------------------
class _FakeOpener:
    """Stand-in for ``urllib.request.OpenerDirector`` used by api-probe."""

    def __init__(self, responses: dict[str, Any]):
        # responses: url-substring -> (status, body_bytes) or Exception instance
        self.responses = responses
        self.calls: list[tuple[str, dict[str, str], bytes | None]] = []

    def open(self, req, timeout=None):  # noqa: D401 - mimic stdlib signature
        url = req.full_url
        self.calls.append((url, dict(req.headers), req.data))
        match = None
        for key, resp in self.responses.items():
            if key in url:
                match = resp
                break
        if match is None:
            raise urllib.error.URLError(f"no fake response for {url}")
        if isinstance(match, Exception):
            raise match
        status, body = match
        if status >= 400:
            err = urllib.error.HTTPError(url, status, "fake", {}, io.BytesIO(body))
            raise err

        class _Resp:
            def __init__(self, status: int, body: bytes):
                self.status = status
                self._body = body

            def read(self) -> bytes:
                return self._body

        return _Resp(status, body)


def _run_main(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture,
    argv: list[str],
    opener: _FakeOpener | None = None,
    tls_result: dict[str, Any] | None = None,
) -> tuple[int, dict[str, Any], _FakeOpener | None]:
    """Invoke ``probe.main`` and return ``(exit_code, json_report, opener)``."""

    monkeypatch.setattr(sys, "argv", ["api-probe.py", *argv])
    if opener is not None:
        monkeypatch.setattr(probe, "build_opener", lambda ctx: opener)
    monkeypatch.setattr(
        probe,
        "tls_info",
        lambda url, ctx: tls_result if tls_result is not None else {"cert_issuer": "Fake CA"},
    )
    monkeypatch.setattr(probe, "build_ssl_context", lambda: ssl.create_default_context())

    with pytest.raises(SystemExit) as exc:
        probe.main()
    out = capsys.readouterr().out
    # main() always calls emit() which dumps a JSON object then exits.
    report = json.loads(out)
    return int(exc.value.code or 0), report, opener


# ---------------------------------------------------------------------------
# 1. Backend auto-detection
# ---------------------------------------------------------------------------
@pytest.mark.parametrize(
    "url,expected",
    [
        ("https://api.anthropic.com", "anthropic"),
        ("https://api.openai.com/v1", "openai"),
        ("https://corp.openai.azure.com", "azure"),
        ("https://us-central1-aiplatform.googleapis.com", "vertex"),
        ("https://litellm.internal.corp/api", "litellm"),
        ("https://bedrock-proxy.internal/v1", "bedrock-proxy"),
        ("https://unknown.example.com", "openai"),  # safe default
    ],
)
def test_detect_backend(url: str, expected: str) -> None:
    assert probe.detect_backend(url) == expected


# ---------------------------------------------------------------------------
# 2. Auth header per backend
# ---------------------------------------------------------------------------
def test_auth_headers_anthropic() -> None:
    h = probe.auth_headers("anthropic", "sk-ant-secret")
    assert h["x-api-key"] == "sk-ant-secret"
    assert h["anthropic-version"] == "2023-06-01"
    assert "Authorization" not in h
    assert "api-key" not in h


def test_auth_headers_azure() -> None:
    h = probe.auth_headers("azure", "azure-secret")
    assert h["api-key"] == "azure-secret"
    assert "Authorization" not in h
    assert "x-api-key" not in h


@pytest.mark.parametrize("backend", ["openai", "litellm", "vertex", "bedrock-proxy"])
def test_auth_headers_bearer(backend: str) -> None:
    h = probe.auth_headers(backend, "tok123")
    assert h["Authorization"] == "Bearer tok123"
    assert "x-api-key" not in h
    assert "api-key" not in h


def test_auth_label_mapping() -> None:
    assert probe.auth_label("anthropic") == "x-api-key"
    assert probe.auth_label("azure") == "api-key-header"
    assert probe.auth_label("openai") == "bearer-token"
    assert probe.auth_label("litellm") == "bearer-token"


# ---------------------------------------------------------------------------
# 3. /v1/models endpoint parses + returns model list
# ---------------------------------------------------------------------------
def test_parse_models_openai_shape() -> None:
    body = json.dumps({"data": [{"id": "gpt-4"}, {"id": "gpt-3.5"}]}).encode()
    assert probe.parse_models("openai", body) == ["gpt-4", "gpt-3.5"]


def test_parse_models_anthropic_shape() -> None:
    body = json.dumps({"data": [{"id": "claude-3-opus"}, {"id": "claude-3-sonnet"}]}).encode()
    assert probe.parse_models("anthropic", body) == ["claude-3-opus", "claude-3-sonnet"]


def test_parse_models_azure_value_shape() -> None:
    body = json.dumps({"value": [{"id": "gpt-4-azure"}]}).encode()
    assert probe.parse_models("azure", body) == ["gpt-4-azure"]


def test_parse_models_string_list() -> None:
    body = json.dumps({"models": ["a", "b", "c"]}).encode()
    assert probe.parse_models("litellm", body) == ["a", "b", "c"]


def test_parse_models_invalid_json() -> None:
    assert probe.parse_models("openai", b"not-json") == []


def test_main_lists_models(monkeypatch, capsys) -> None:
    body = json.dumps({"data": [{"id": "gpt-4"}, {"id": "gpt-3.5"}]}).encode()
    opener = _FakeOpener({"/v1/models": (200, body)})
    code, report, _ = _run_main(
        monkeypatch,
        capsys,
        ["--url", "https://api.openai.com", "--token", "sk-test-1234567890"],
        opener=opener,
    )
    assert code == 0
    assert report["ok"] is True
    assert report["models_available"] == ["gpt-4", "gpt-3.5"]
    assert report["backend"] == "openai"


# ---------------------------------------------------------------------------
# 4. Fallback to minimal completion when /models 4xx (but not auth-fail)
# ---------------------------------------------------------------------------
def test_fallback_completion_on_models_4xx(monkeypatch, capsys) -> None:
    # /models returns 404 → fallback POST /v1/chat/completions returns 200
    opener = _FakeOpener(
        {
            "/v1/models": (404, b'{"error":"not found"}'),
            "/v1/chat/completions": (200, b'{"id":"x"}'),
        }
    )
    code, report, op = _run_main(
        monkeypatch,
        capsys,
        [
            "--url",
            "https://litellm.corp.local",
            "--token",
            "tok-abcdefgh",
            "--model",
            "gpt-4",
        ],
        opener=opener,
    )
    assert code == 0
    assert report["ok"] is True
    assert "fallback" in report
    assert report["fallback"]["http_status"] == 200
    # confirm we actually hit the chat completions URL
    assert op is not None
    assert any("/v1/chat/completions" in url for url, _, _ in op.calls)


# ---------------------------------------------------------------------------
# 5. Token masking: never log token, never include in JSON output
# ---------------------------------------------------------------------------
def test_mask_token_short() -> None:
    assert probe.mask_token("") == ""
    assert probe.mask_token("abc") == "***"
    assert probe.mask_token("12345678") == "***"


def test_mask_token_long() -> None:
    masked = probe.mask_token("sk-ant-supersecrettoken")
    assert masked == "sk-a...oken"
    assert "supersecret" not in masked


def test_token_never_in_output(monkeypatch, capsys) -> None:
    secret = "sk-ant-DO-NOT-LEAK-1234567890"
    opener = _FakeOpener({"/v1/models": (200, json.dumps({"data": []}).encode())})
    code, report, _ = _run_main(
        monkeypatch,
        capsys,
        ["--url", "https://api.anthropic.com", "--token", secret],
        opener=opener,
    )
    assert code == 0
    raw = json.dumps(report)
    assert secret not in raw
    assert "DO-NOT-LEAK" not in raw
    assert report["token_preview"] == probe.mask_token(secret)


# ---------------------------------------------------------------------------
# 6. Exit codes: 0 OK, 2 auth fail (401), 3 unreachable, 4 cert error, 5 bad URL
# ---------------------------------------------------------------------------
def test_exit_0_ok(monkeypatch, capsys) -> None:
    opener = _FakeOpener({"/v1/models": (200, json.dumps({"data": []}).encode())})
    code, report, _ = _run_main(
        monkeypatch,
        capsys,
        ["--url", "https://api.openai.com", "--token", "tok-abcdefgh"],
        opener=opener,
    )
    assert code == 0
    assert report["ok"] is True


def test_exit_2_auth_failed_401(monkeypatch, capsys) -> None:
    opener = _FakeOpener({"/v1/models": (401, b'{"error":"unauthorized"}')})
    code, report, _ = _run_main(
        monkeypatch,
        capsys,
        ["--url", "https://api.openai.com", "--token", "bad-tok-12345"],
        opener=opener,
    )
    assert code == 2
    assert report["ok"] is False
    assert report["error"] == "auth-failed"


def test_exit_2_auth_failed_403(monkeypatch, capsys) -> None:
    opener = _FakeOpener({"/v1/models": (403, b"")})
    code, report, _ = _run_main(
        monkeypatch,
        capsys,
        ["--url", "https://api.openai.com", "--token", "bad-tok-12345"],
        opener=opener,
    )
    assert code == 2
    assert report["error"] == "auth-failed"


def test_exit_3_unreachable(monkeypatch, capsys) -> None:
    err = urllib.error.URLError(ConnectionRefusedError("connection refused"))
    opener = _FakeOpener({"/v1/models": err})
    code, report, _ = _run_main(
        monkeypatch,
        capsys,
        ["--url", "https://api.openai.com", "--token", "tok-abcdefgh"],
        opener=opener,
    )
    assert code == 3
    assert report["ok"] is False


def test_exit_4_cert_error_via_urlerror(monkeypatch, capsys) -> None:
    err = urllib.error.URLError("certificate verify failed: self-signed certificate")
    opener = _FakeOpener({"/v1/models": err})
    code, report, _ = _run_main(
        monkeypatch,
        capsys,
        ["--url", "https://api.openai.com", "--token", "tok-abcdefgh"],
        opener=opener,
    )
    assert code == 4


def test_exit_4_cert_error_via_tls_info(monkeypatch, capsys) -> None:
    code, report, _ = _run_main(
        monkeypatch,
        capsys,
        ["--url", "https://api.openai.com", "--token", "tok-abcdefgh"],
        opener=_FakeOpener({"/v1/models": (200, b"{}")}),
        tls_result={"error": "ssl: handshake failure"},
    )
    assert code == 4
    assert report["error"] == "tls-error"


def test_exit_5_bad_url(monkeypatch, capsys) -> None:
    code, report, _ = _run_main(
        monkeypatch,
        capsys,
        ["--url", "not-a-url", "--token", "tok-abcdefgh"],
    )
    assert code == 5
    assert report["error"] == "bad-url"


# ---------------------------------------------------------------------------
# 7. Output JSON schema: required keys present on success
# ---------------------------------------------------------------------------
REQUIRED_KEYS = {"ok", "backend", "url", "auth", "latency_ms", "models_available"}


def test_success_report_schema(monkeypatch, capsys) -> None:
    opener = _FakeOpener({"/v1/models": (200, json.dumps({"data": [{"id": "m"}]}).encode())})
    code, report, _ = _run_main(
        monkeypatch,
        capsys,
        ["--url", "https://api.openai.com", "--token", "tok-abcdefgh"],
        opener=opener,
    )
    assert code == 0
    missing = REQUIRED_KEYS - set(report.keys())
    assert not missing, f"missing keys: {missing}"
    assert report["auth"] == "bearer-token"
    assert isinstance(report["latency_ms"], (int, float))
    assert isinstance(report["models_available"], list)
    assert "token_preview" in report  # mask present, raw token absent
