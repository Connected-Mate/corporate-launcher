"""Tests for scripts/load-test.py — corporate AI gateway load tester.

All network I/O is mocked: ``urllib.request.OpenerDirector.open`` is replaced
with a fake that records every call and returns canned responses. No real
sockets are opened.

Pins behaviour for:
  * concurrency + total request count (N=10, c=2)
  * latency percentile math (p50 of [1..5] == 3)
  * HTTP error capture (429 in ``error_codes``)
  * connection timeout handled, not crashed
  * token never echoed verbatim in the JSON report
  * --burst mode fires N requests as workers
  * safety threshold (>100 without --yes -> exit 5)
  * JSON output schema (req_per_sec / tokens_per_sec / latency_ms keys)
"""

from __future__ import annotations

import importlib.util
import io
import json
import sys
import urllib.error
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, patch

import pytest

# --------------------------------------------------------------------------- #
# Module loader — load-test.py is a script with a hyphen in its name.         #
# --------------------------------------------------------------------------- #

REPO_ROOT = Path(__file__).resolve().parent.parent
LOAD_TEST_PATH = REPO_ROOT / "scripts" / "load-test.py"


def _load_module() -> Any:
    if not LOAD_TEST_PATH.exists():
        pytest.skip(f"load-test.py not yet implemented at {LOAD_TEST_PATH}")
    spec = importlib.util.spec_from_file_location("load_test", LOAD_TEST_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["load_test"] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def lt() -> Any:
    return _load_module()


# --------------------------------------------------------------------------- #
# Fake HTTP response helpers                                                  #
# --------------------------------------------------------------------------- #


def _fake_response(
    status: int = 200,
    body: dict[str, Any] | None = None,
) -> MagicMock:
    body = body or {"usage": {"total_tokens": 5}, "choices": [{"text": "OK"}]}
    resp = MagicMock()
    resp.status = status
    resp.read.return_value = json.dumps(body).encode("utf-8")
    return resp


class _FakeOpener:
    """Drop-in replacement for an OpenerDirector that counts calls."""

    def __init__(self, responder: Any) -> None:
        self.calls: list[Any] = []
        self._responder = responder

    def open(self, req: Any, timeout: float = 30.0) -> Any:
        self.calls.append(req)
        result = self._responder(len(self.calls) - 1, req)
        if isinstance(result, Exception):
            raise result
        return result


# --------------------------------------------------------------------------- #
# 1. N=10 concurrency=2 — 10 calls fired, percentile keys present             #
# --------------------------------------------------------------------------- #


def test_ten_requests_concurrency_two_produces_percentiles(lt: Any) -> None:
    fake = _FakeOpener(lambda i, req: _fake_response())
    with patch.object(lt, "build_opener", return_value=fake):
        report = lt.run_load(
            url="https://gw.example/v1/chat/completions",
            token="sk-secret",
            backend="openai",
            model="gpt-4o-mini",
            prompt="ping",
            total=10,
            concurrency=2,
            timeout=5.0,
            burst=False,
        )

    assert len(fake.calls) == 10
    assert report["total"] == 10
    assert report["completed"] == 10
    assert {"p50", "p95", "p99"} <= set(report["latency_ms"].keys())


# --------------------------------------------------------------------------- #
# 2. Percentile math                                                          #
# --------------------------------------------------------------------------- #


def test_percentile_p50_of_one_through_five_is_three(lt: Any) -> None:
    assert lt.percentile([1.0, 2.0, 3.0, 4.0, 5.0], 50) == pytest.approx(3.0)
    assert lt.percentile([1.0, 2.0, 3.0, 4.0, 5.0], 100) == pytest.approx(5.0)
    assert lt.percentile([], 50) == 0.0


# --------------------------------------------------------------------------- #
# 3. HTTP 429 captured in error_codes                                         #
# --------------------------------------------------------------------------- #


def test_http_429_captured_in_error_codes(lt: Any) -> None:
    def responder(i: int, req: Any) -> Any:
        return urllib.error.HTTPError(
            url=req.full_url,
            code=429,
            msg="Too Many Requests",
            hdrs=None,  # type: ignore[arg-type]
            fp=io.BytesIO(b'{"error":"rate limited"}'),
        )

    fake = _FakeOpener(responder)
    with patch.object(lt, "build_opener", return_value=fake):
        report = lt.run_load(
            url="https://gw.example",
            token="sk-secret",
            backend="openai",
            model="m",
            prompt="p",
            total=4,
            concurrency=2,
            timeout=5.0,
            burst=False,
        )

    assert report["errors"] == 4
    assert report["completed"] == 0
    assert report["error_codes"].get("429") == 4


# --------------------------------------------------------------------------- #
# 4. Connection timeout is counted, not crashed                               #
# --------------------------------------------------------------------------- #


def test_connection_timeout_does_not_crash(lt: Any) -> None:
    def responder(i: int, req: Any) -> Any:
        return urllib.error.URLError("timed out")

    fake = _FakeOpener(responder)
    with patch.object(lt, "build_opener", return_value=fake):
        report = lt.run_load(
            url="https://gw.example",
            token="sk-secret",
            backend="openai",
            model="m",
            prompt="p",
            total=3,
            concurrency=1,
            timeout=0.1,
            burst=False,
        )

    assert report["errors"] == 3
    assert report["completed"] == 0
    # Network-level errors bucketed under "network" sentinel
    assert "network" in report["error_codes"]


# --------------------------------------------------------------------------- #
# 5. Token must not leak into the JSON report                                 #
# --------------------------------------------------------------------------- #


def test_token_not_present_in_output(lt: Any) -> None:
    secret = "sk-supersecret-DO-NOT-LEAK-123"
    fake = _FakeOpener(lambda i, req: _fake_response())
    with patch.object(lt, "build_opener", return_value=fake):
        report = lt.run_load(
            url="https://gw.example",
            token=secret,
            backend="openai",
            model="m",
            prompt="p",
            total=2,
            concurrency=1,
            timeout=5.0,
            burst=False,
        )

    blob = json.dumps(report)
    assert secret not in blob


# --------------------------------------------------------------------------- #
# 6. --burst mode fires N requests with N workers                             #
# --------------------------------------------------------------------------- #


def test_burst_mode_uses_total_as_worker_count(lt: Any) -> None:
    fake = _FakeOpener(lambda i, req: _fake_response())
    with patch.object(lt, "build_opener", return_value=fake):
        report = lt.run_load(
            url="https://gw.example",
            token="t",
            backend="openai",
            model="m",
            prompt="p",
            total=7,
            concurrency=1,
            timeout=5.0,
            burst=True,
        )

    assert len(fake.calls) == 7
    assert report["mode"] == "burst"
    assert report["concurrency"] == 7


# --------------------------------------------------------------------------- #
# 7. Safety threshold: >100 requests without --yes refuses                    #
# --------------------------------------------------------------------------- #


def test_safety_threshold_blocks_without_yes(
    lt: Any, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "load-test.py",
            "--url", "https://gw.example",
            "--token", "t",
            "--total", "500",
            "--concurrency", "10",
        ],
    )
    # ensure run_load is never reached
    with patch.object(lt, "run_load", side_effect=AssertionError("should not run")):
        rc = lt.main()

    assert rc == 5
    err = capsys.readouterr().err
    assert "refusing" in err or "safety_threshold" in err


def test_safety_threshold_allows_with_yes(
    lt: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "load-test.py",
            "--url", "https://gw.example",
            "--token", "t",
            "--total", "150",
            "--concurrency", "5",
            "--yes",
        ],
    )
    fake_report = {
        "completed": 150,
        "errors": 0,
        "error_codes": {},
        "latency_ms": {"p50": 1, "p95": 2, "p99": 3, "max": 4},
    }
    with patch.object(lt, "run_load", return_value=fake_report):
        rc = lt.main()
    assert rc == 0


# --------------------------------------------------------------------------- #
# 8. JSON output schema — required keys present                               #
# --------------------------------------------------------------------------- #


REQUIRED_TOP_LEVEL = {
    "url",
    "model",
    "backend",
    "mode",
    "concurrency",
    "total",
    "completed",
    "errors",
    "error_codes",
    "latency_ms",
    "wall_seconds",
    "tokens_per_sec",
    "req_per_sec",
}


def test_report_schema_has_required_keys(lt: Any) -> None:
    fake = _FakeOpener(lambda i, req: _fake_response())
    with patch.object(lt, "build_opener", return_value=fake):
        report = lt.run_load(
            url="https://gw.example",
            token="t",
            backend="openai",
            model="m",
            prompt="p",
            total=3,
            concurrency=1,
            timeout=5.0,
            burst=False,
        )

    missing = REQUIRED_TOP_LEVEL - set(report.keys())
    assert not missing, f"missing schema keys: {missing}"
    assert {"p50", "p95", "p99", "max"} <= set(report["latency_ms"].keys())
    assert isinstance(report["req_per_sec"], (int, float))
    assert isinstance(report["tokens_per_sec"], (int, float))
