#!/usr/bin/env python3
"""${CORP_NAME} — cost tracker.

Reads SSE events from /tmp/${CORP_SLUG}-strip-proxy-usage.jsonl and aggregates
per-session, per-day, per-model costs in ${COST_CURRENCY}.

The strip-proxy writes one JSON line per response containing:
    {"ts": "...", "model": "...", "usage": {...}, "cost": 0.0042}

Pricing table is loaded from pricing.json next to this script — edit there to
match your gateway's contracted rates.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict
from pathlib import Path

CURRENCY = "${COST_CURRENCY}"
USAGE_LOG = Path(os.environ.get("${CORP_SLUG_UPPER}_USAGE_LOG", "/tmp/${CORP_SLUG}-usage.jsonl"))


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


def cmd_session(args: argparse.Namespace) -> int:
    events = load_events(USAGE_LOG)
    session = os.environ.get("${CORP_SLUG_UPPER}_SESSION_ID")
    if session:
        events = [e for e in events if e.get("session") == session]
    total = sum(e.get("cost", 0.0) for e in events)
    print(f"${CORP_NAME} — current session: {fmt(total)}  ({len(events)} requests)")
    return 0


def cmd_today(args: argparse.Namespace) -> int:
    import datetime as _dt

    today = _dt.date.today().isoformat()
    events = [e for e in load_events(USAGE_LOG) if (e.get("ts", "")[:10] == today)]
    total = sum(e.get("cost", 0.0) for e in events)
    by_model: dict[str, float] = defaultdict(float)
    for e in events:
        by_model[e.get("model", "?")] += e.get("cost", 0.0)
    print(f"${CORP_NAME} — today ({today}): {fmt(total)}  ({len(events)} requests)")
    for model, cost in sorted(by_model.items(), key=lambda x: -x[1]):
        print(f"  {model:<30s} {fmt(cost)}")
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


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("session").set_defaults(func=cmd_session)
    sub.add_parser("today").set_defaults(func=cmd_today)
    sub.add_parser("history").set_defaults(func=cmd_history)
    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
