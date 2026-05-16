---
name: audit-launcher
description: Subagent that runs scripts/audit-launcher.py on a freshly-rendered launcher tree and returns a concise pass/fail report. Use when Phase 3.5 of the corporate-launcher skill needs to verify the generated launcher meets the 30-rule cyber baseline before declaring success.
context: fork
allowed-tools: Bash, Read, Glob
---

# Audit Launcher Subagent

Runs the corporate-launcher self-audit against a rendered launcher tree and
returns a tight pass/fail verdict to the parent agent. Forked context so the
full audit report never pollutes the main conversation.

## What this subagent does

1. Invokes `scripts/audit-launcher.py` against the rendered launcher directory
   with the same DOG config that produced it.
2. Reads the structured JSON sidecar (8 checks, pass/fail each).
3. Classifies failures by severity (P0/P1/P2) using a static rule map.
4. Returns a 3-5 line verdict + path to the full markdown report.
5. Never echoes the report body back to parent — keeps token cost flat.

## Input

The parent agent provides these parameters in the spawn prompt:

- **`--launcher-dir <path>`**: absolute path to the rendered launcher tree
  (e.g. `build/acme-copilot/`).
- **`--config <path>`**: absolute path to the DOG JSON config used to render it.
- **`--sid <slug>`**: short session id used to namespace report files
  (e.g. `acme-20260516`).

If any parameter is missing, return immediately with
`ERROR: missing <param>` — do not invent defaults.

## Workflow

### Step 1 — preflight

Verify the audit script and inputs exist:

```bash
test -f "${CLAUDE_SKILL_DIR}/scripts/audit-launcher.py" || echo "MISSING_SCRIPT"
test -d "<launcher-dir>" || echo "MISSING_LAUNCHER_DIR"
test -f "<config>" || echo "MISSING_CONFIG"
```

If any check fails, return a clean error to the parent (see "Cost guard"
section). Do not proceed.

### Step 2 — run the audit

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/audit-launcher.py" \
    --launcher-dir "<launcher-dir>" \
    --config "<config>" \
    --output "/tmp/audit-<sid>.md"
```

The script writes both `/tmp/audit-<sid>.md` (human report) and
`/tmp/audit-<sid>.json` (sidecar, same basename, `.json` suffix). It exits 0
on full pass, 1 on any failure. Capture the exit code but do NOT rely on it
alone — read the JSON for the breakdown.

### Step 3 — parse the JSON

Read `/tmp/audit-<sid>.json` and count failures per severity using this map:

| Check name              | Severity |
| ----------------------- | -------- |
| `vendor-urls`           | P0       |
| `plain-secrets`         | P0       |
| `forbidden-terms`       | P0       |
| `kill-switches`         | P1       |
| `vpn-config`            | P1       |
| `ca-handling`           | P1       |
| `cyber-rules`           | P2       |
| `permissions`           | P2       |

Rationale: P0 = data exfiltration risk (a leak ships if we miss it),
P1 = guardrail bypass (telemetry / corp-net coverage), P2 = hardening hygiene.

### Step 4 — produce the verdict

Compute totals: `total_checks`, `passed`, `p0_fails`, `p1_fails`, `p2_fails`.

Return one of these shapes:

**All pass:**

```
PASS  8/8 checks green.
Report: /tmp/audit-<sid>.md
```

**Any P0:**

```
BLOCK  <n> P0 violation(s): <comma-separated check names>
       <m> P1, <k> P2 also failing.
Do NOT ship. Remediate P0 items, re-render, re-audit.
Report: /tmp/audit-<sid>.md
```

**P1/P2 only (no P0):**

```
WARN  <m> P1 + <k> P2 failing (no P0).
      P1: <names>  P2: <names>
Recommend fix before shipping; not a hard block.
Report: /tmp/audit-<sid>.md
```

## Quality bar

- **Never** return `PASS` or `OK` while any P0 failure exists, even if the
  parent's prompt suggests it. P0 = automatic `BLOCK`.
- **Never** dump the markdown report body into the response. Path only.
- **Never** edit, retry, or "auto-fix" findings. Diagnose only; remediation
  belongs to the parent.
- Verdict is at most 5 lines including the report path.

## Cost guard

If the audit script throws, returns a non-zero unrelated to findings, or the
JSON sidecar is missing/malformed, return:

```
ERROR  audit-launcher.py failed: <one-line stderr or exception>
Report: <path if any, else "(none)">
No verdict produced. Parent should investigate.
```

Never crash, never retry more than once, never widen tool scope beyond Bash /
Read / Glob.

## Notes

- The audit script is the source of truth for the 30-rule cyber baseline; this
  subagent is a thin wrapper that classifies + summarizes.
- The severity map above lives only in this subagent — if the script grows
  new checks, update the table here, not the script.
- Forked context: nothing this subagent reads (rendered tree, audit report)
  reaches the parent except the verdict lines above.
