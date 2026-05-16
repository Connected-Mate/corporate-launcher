#!/usr/bin/env python3
"""${CORP_NAME} — cost tracker.

Reads usage events from /tmp/${CORP_SLUG}-usage.jsonl and aggregates
per-session, per-day, per-model costs in ${COST_CURRENCY}.

Event line format (one JSON object per line):
    {"ts": "...", "model": "...", "usage": {...}, "cost": 0.0042, "session": "..."}

Producers:
  - templates/shared/strip-proxy.js (Bedrock/LiteLLM SSE intercept)
  - any per-CLI ingest adapter that writes the same schema

Pricing table is loaded from pricing.json next to this script — edit there to
match your gateway's contracted rates.

Optional alerting:
  - COST_ALERT_THRESHOLD (in COST_CURRENCY units, daily). When today's spend
    exceeds the threshold, `--cost session` and `--cost today` print a
    non-fatal warning. Zero or absent disables the alert.

Optional tenant push (corporate dashboard):
  - COST_TENANT_ENDPOINT — HTTPS URL the tracker POSTs aggregated daily totals
    to when invoked with `--cost push`. POST body is one JSON document.
    Auth header comes from COST_TENANT_TOKEN (Bearer). Absence of either
    disables the push.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from pathlib import Path

CURRENCY = "${COST_CURRENCY}"
USAGE_LOG = Path(os.environ.get("${CORP_SLUG_UPPER}_USAGE_LOG", "/tmp/${CORP_SLUG}-usage.jsonl"))
ALERT_THRESHOLD = float(os.environ.get("${CORP_SLUG_UPPER}_COST_ALERT_THRESHOLD", "${COST_ALERT_THRESHOLD}") or 0)
TENANT_ENDPOINT = os.environ.get("${CORP_SLUG_UPPER}_COST_TENANT_ENDPOINT", "${COST_TENANT_ENDPOINT}")
TENANT_TOKEN = os.environ.get("${CORP_SLUG_UPPER}_COST_TENANT_TOKEN", "")


def fmt(amount: float) -> str:
    if CURRENCY == "EUR":
        return f"{amount:.4f} €"
    if CURRENCY == "USD":
        return f"$ {amount:.4f}"
    return f"{amount:.4f} {CURRENCY}"


def load_events(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    events: list[dict] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return events


def today_total(events: list[dict]) -> float:
    import datetime as _dt
    today = _dt.date.today().isoformat()
    return sum(e.get("cost", 0.0) for e in events if e.get("ts", "")[:10] == today)


def maybe_alert(events: list[dict]) -> None:
    if ALERT_THRESHOLD <= 0:
        return
    total_today = today_total(events)
    if total_today >= ALERT_THRESHOLD:
        print(
            f"  [!] daily cost {fmt(total_today)} ≥ alert threshold {fmt(ALERT_THRESHOLD)}",
            file=sys.stderr,
        )


def cmd_session(args: argparse.Namespace) -> int:
    events = load_events(USAGE_LOG)
    session = os.environ.get("${CORP_SLUG_UPPER}_SESSION_ID")
    scoped = [e for e in events if e.get("session") == session] if session else events
    total = sum(e.get("cost", 0.0) for e in scoped)
    print(f"${CORP_NAME} — current session: {fmt(total)}  ({len(scoped)} requests)")
    maybe_alert(events)
    return 0


def cmd_today(args: argparse.Namespace) -> int:
    import datetime as _dt

    today = _dt.date.today().isoformat()
    events = load_events(USAGE_LOG)
    today_events = [e for e in events if (e.get("ts", "")[:10] == today)]
    total = sum(e.get("cost", 0.0) for e in today_events)
    by_model: dict[str, float] = defaultdict(float)
    for e in today_events:
        by_model[e.get("model", "?")] += e.get("cost", 0.0)
    print(f"${CORP_NAME} — today ({today}): {fmt(total)}  ({len(today_events)} requests)")
    for model, cost in sorted(by_model.items(), key=lambda x: -x[1]):
        print(f"  {model:<30s} {fmt(cost)}")
    maybe_alert(events)
    return 0


def cmd_history(args: argparse.Namespace) -> int:
    by_day: dict[str, float] = defaultdict(float)
    for e in load_events(USAGE_LOG):
        day = (e.get("ts", "")[:10]) or "?"
        by_day[day] += e.get("cost", 0.0)
    print(f"${CORP_NAME} — history:")
    for day in sorted(by_day.keys()):
        print(f"  {day}  {fmt(by_day[day])}")
    return 0


def cmd_push(args: argparse.Namespace) -> int:
    """POST today's aggregated total to the corporate tenant dashboard."""
    if not TENANT_ENDPOINT:
        print("push disabled — set COST_TENANT_ENDPOINT to enable", file=sys.stderr)
        return 2

    import datetime as _dt
    today = _dt.date.today().isoformat()
    events = [e for e in load_events(USAGE_LOG) if e.get("ts", "")[:10] == today]
    payload = {
        "tenant": "${CORP_SLUG}",
        "org": "${CORP_ORGANIZATION}",
        "day": today,
        "currency": CURRENCY,
        "total": round(sum(e.get("cost", 0.0) for e in events), 6),
        "requests": len(events),
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        TENANT_ENDPOINT,
        data=data,
        method="POST",
        headers={"Content-Type": "application/json", "User-Agent": "${CORP_SLUG}-cost-tracker"},
    )
    if TENANT_TOKEN:
        req.add_header("Authorization", f"Bearer {TENANT_TOKEN}")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            print(f"pushed {fmt(payload['total'])} for {today} → HTTP {resp.status}")
            return 0
    except urllib.error.HTTPError as exc:
        print(f"push failed: HTTP {exc.code}", file=sys.stderr)
        return 1
    except urllib.error.URLError as exc:
        print(f"push failed: {exc.reason}", file=sys.stderr)
        return 1


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("session").set_defaults(func=cmd_session)
    sub.add_parser("today").set_defaults(func=cmd_today)
    sub.add_parser("history").set_defaults(func=cmd_history)
    sub.add_parser("push").set_defaults(func=cmd_push)
    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
