#!/usr/bin/env python3
"""Per-team / per-org cost rollup.

Aggregates daily totals from N launcher tenants into a single record and POSTs
it to an org-level FinOps endpoint. Designed to run on a central cron host
(not on developer laptops) once a day.

Input modes:
  --from-dir <DIR>
      Read every `*.jsonl` file under DIR. Each file is a tenant's local
      usage log (the `/tmp/<slug>-usage.jsonl` produced by cost-tracker).
      Mount this dir from S3 / NFS / GCS where launchers push their daily
      snapshot.

  --from-http-archive <DIR>
      Read every `*.json` file under DIR. Each file is one tenant's daily
      payload (the body of `<launcher> --cost push`) as received by an
      HTTP relay and persisted to disk.

Output:
  --post <URL>         POST a single aggregated JSON record (default).
  --print              print the rollup to stdout (debug).

Aggregated payload:
  {
    "org": "<from --org>",
    "day": "<--day, default today UTC>",
    "currency": "<from first tenant, all must match>",
    "tenants": [
      {"tenant": "...", "total": ..., "requests": ...},
      ...
    ],
    "grand_total": <sum>,
    "grand_requests": <sum>,
    "tenant_count": N
  }

Auth (optional): --bearer <TOKEN> sends Authorization: Bearer.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from pathlib import Path


def load_jsonl(path: Path) -> list[dict]:
    out: list[dict] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def rollup_from_jsonl_dir(src: Path, day: str) -> dict:
    """Tenant slug = filename stem (e.g. acme-copilot-usage.jsonl → acme-copilot)."""
    tenants: dict[str, dict] = {}
    currencies: set[str] = set()
    for f in sorted(src.glob("*.jsonl")):
        slug = f.stem.removesuffix("-usage")
        events = [e for e in load_jsonl(f) if e.get("ts", "")[:10] == day]
        if not events:
            continue
        total = round(sum(e.get("cost", 0.0) for e in events), 6)
        ccy = next((e["currency"] for e in events if "currency" in e), "")
        if ccy:
            currencies.add(ccy)
        tenants[slug] = {"tenant": slug, "total": total, "requests": len(events)}
    return _finalize(tenants, currencies, day)


def rollup_from_http_archive(src: Path, day: str) -> dict:
    """Each *.json file is one push payload."""
    tenants: dict[str, dict] = defaultdict(lambda: {"tenant": "", "total": 0.0, "requests": 0})
    currencies: set[str] = set()
    for f in sorted(src.glob("*.json")):
        try:
            payload = json.loads(f.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        if payload.get("day") != day:
            continue
        slug = payload.get("tenant", f.stem)
        tenants[slug]["tenant"] = slug
        tenants[slug]["total"] = round(tenants[slug]["total"] + payload.get("total", 0.0), 6)
        tenants[slug]["requests"] += int(payload.get("requests", 0))
        if payload.get("currency"):
            currencies.add(payload["currency"])
    return _finalize(dict(tenants), currencies, day)


def _finalize(tenants: dict, currencies: set, day: str) -> dict:
    if len(currencies) > 1:
        print(
            f"warning: mixed currencies across tenants {sorted(currencies)} — "
            "rollup totals may be misleading.",
            file=sys.stderr,
        )
    currency = next(iter(currencies), "")
    rows = sorted(tenants.values(), key=lambda r: -r["total"])
    return {
        "day": day,
        "currency": currency,
        "tenants": rows,
        "grand_total": round(sum(r["total"] for r in rows), 6),
        "grand_requests": sum(r["requests"] for r in rows),
        "tenant_count": len(rows),
    }


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--from-dir", type=Path, help="Directory of *.jsonl tenant logs")
    src.add_argument("--from-http-archive", type=Path, help="Directory of *.json push payloads")
    p.add_argument("--org", required=True, help="Org label injected into payload")
    p.add_argument("--day", default=_dt.date.today().isoformat(), help="ISO date (default: today UTC)")
    p.add_argument("--post", help="POST the aggregated payload to this URL")
    p.add_argument("--bearer", help="Optional bearer token for --post")
    p.add_argument("--print", action="store_true", help="Print to stdout instead of POST")
    args = p.parse_args(argv)

    if args.from_dir:
        if not args.from_dir.is_dir():
            print(f"error: {args.from_dir} is not a directory", file=sys.stderr)
            return 2
        payload = rollup_from_jsonl_dir(args.from_dir, args.day)
    else:
        if not args.from_http_archive.is_dir():
            print(f"error: {args.from_http_archive} is not a directory", file=sys.stderr)
            return 2
        payload = rollup_from_http_archive(args.from_http_archive, args.day)

    payload["org"] = args.org

    if args.print or not args.post:
        print(json.dumps(payload, indent=2))
        return 0

    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        args.post,
        data=body,
        method="POST",
        headers={"Content-Type": "application/json", "User-Agent": "corporate-launcher-cost-rollup"},
    )
    if args.bearer:
        req.add_header("Authorization", f"Bearer {args.bearer}")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            print(f"rollup posted: {payload['tenant_count']} tenants, "
                  f"grand_total={payload['grand_total']} {payload['currency']} → HTTP {resp.status}")
            return 0
    except urllib.error.HTTPError as exc:
        print(f"post failed: HTTP {exc.code}", file=sys.stderr)
        return 1
    except urllib.error.URLError as exc:
        print(f"post failed: {exc.reason}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
