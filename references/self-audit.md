# Self-Audit Phase

After the launcher is generated, the skill automatically runs `scripts/audit-launcher.py` against its own output and reports back to the user. **The skill never declares success without verifying its own work.**

This page documents what the audit checks, how findings are surfaced, and how to wire it into CI.

---

## 1. Purpose

Generation is template-driven and the interview is human-driven, so the rendered bundle can drift from the security contract in three ways:

- a config value is internally consistent but wrong for the chosen backend (e.g. an Anthropic model ID on a LiteLLM-fronted Bedrock pool),
- a guardrail the user toggled in the interview was not actually wired into the binary (e.g. `VPN_REQUIRED=yes` but `check_vpn` is missing),
- the rendered tree leaked a vendor URL, plaintext key, or forbidden brand term into a file that escapes the corporate gateway story.

The self-audit closes that loop: every Phase 4 finish runs the audit and shows the findings before the skill says "done".

---

## 2. What Gets Checked

The 32 rules in `scripts/audit-rules.json` group into 8 categories. Each category answers one question the platform team will ask at review.

| Category        | Sample rule IDs                                                | What it proves                                                                  |
| --------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `vendor-urls`   | `no-vendor-urls-in-binary`, `no-vendor-urls-in-mcp-config`     | No file outside `BRANDING.md` / `settings.json` deny-list talks to vendor hosts |
| `secrets`       | `no-plain-anthropic-key`, `no-private-keys`, `no-bearer-tokens`| No `sk-ant-…`, `sk-…`, `AIza…`, PEM blocks, or hardcoded Bearer tokens          |
| `vpn`           | `vpn-check-present`, `vpn-check-before-exec`                   | When `VPN_REQUIRED=yes`, `check_vpn` exists **and** runs before `exec`          |
| `branding`      | `branding-sourced`, `cyber-rules-sourced`, `forbidden-terms-…` | Persona is loaded via `--append-system-prompt-file`; vendor names are quarantined to `BRANDING.md` |
| `telemetry`     | `telemetry-kill-switches-exported`, `no-autoupdate`            | Each declared `KILL_SWITCHES` entry is exported; auto-update disabled           |
| `tls`           | `tls-reject-only-if-mitm`, `ca-bundle-referenced`              | `NODE_TLS_REJECT_UNAUTHORIZED=0` only when MITM accepted; otherwise CA bundle wired |
| `proxy`         | `strip-proxy-file-exists`, `strip-proxy-started`               | If `CC_NEEDS_STRIP_PROXY=yes`, `strip-proxy.js` ships **and** is spawned        |
| `permissions`   | `perm-cyber-guard-555`, `perm-settings-600`, `settings-deny-vendor` | Installer sets correct mode bits; `settings.json` deny-list covers vendors |
| `mcp`           | `mcp-servers-in-allowlist`, `mcp-no-stdio-shell`               | Every bundled MCP is in `allowedMcpServers` and not wrapped in `/bin/sh -c`     |
| `supply-chain`  | `no-curl-pipe-shell`, `checksum-verification`                  | Installers don't `curl … | sh`; downloaded artifacts are checksummed            |

---

## 3. Severity Levels

Each rule carries a severity. The skill treats them as a triage queue, not a pass/fail binary.

- **P0 — must fix before ship.** Plaintext secrets, hardcoded vendor URLs, `curl | sh` installers, forbidden brand terms outside `BRANDING.md`. The skill refuses to mark the run successful while any P0 is open.
- **P1 — should fix.** Missing VPN gate, missing kill-switch export, TLS bypass without an accepted MITM policy, MCP server invoked via shell. The skill ships but flags the bundle as "review required".
- **P2 — nice to have.** Mode bits not pinned by the installer, missing checksum verification, MCP missing from `allowedMcpServers`. Reported, not blocking.

---

## 4. Common Findings on First-Time Configs

These are the patterns the audit catches most often when a new platform team renders their first launcher:

- **Wrong model ID for the chosen backend.** `BACKEND_FLAVOR=litellm` but `MODEL_ID=claude-opus-4-7` (vendor name) instead of the gateway alias (`socle-opus-47`). Caught indirectly via `forbidden-terms-only-in-branding`.
- **`VPN_REQUIRED=yes` but no probe URL set.** `VPN_PROBE_URL` empty, so `check_vpn` renders as a no-op. Caught by `vpn-check-present` (the function exists but the rendered body has no `curl` against the probe).
- **`ACCEPT_TLS_INSPECTION=yes` *and* a CA bundle path.** Both knobs were flipped; the bundle is redundant and confuses the install. Caught by `ca-bundle-referenced` + cross-check.
- **`KILL_SWITCHES` listed in config but missing `export` in the binary.** Usually a template typo. Caught by `telemetry-kill-switches-exported`.
- **MCP server present in `.mcp.json` but not in `settings.json -> allowedMcpServers`.** Caught by `mcp-servers-in-allowlist`.
- **Vendor URL leaks into a comment header.** A copy-pasted snippet still says `# fetched from api.anthropic.com`. Caught by `no-vendor-urls-in-binary`.
- **Forbidden term in a skill file.** Bundled skill mentions "Claude" in its description. Caught by `forbidden-terms-only-in-branding`.

---

## 5. How the Skill Presents Findings

At the end of Phase 4, before declaring done, the skill prints a compact summary. P0/P1/P2 items are interleaved in severity order; passing checks are rolled up into the headline count.

```
Self-audit complete: 13/15 checks passed.

- P1: ACCEPT_TLS_INSPECTION=yes but you also provided a CA bundle.
  Recommendation: set ACCEPT_TLS_INSPECTION=no and let the bundle alone.

- P2: Bundled MCP server "github" doesn't appear in your gateway's allowlist.
  Recommendation: ask your platform team to add it.

Full report: build/acme-copilot/audit-report.md
```

If any P0 remains open, the headline changes to `Self-audit FAILED: <n> blocking issue(s)` and the skill refuses to advance to packaging.

---

## 6. Interactive Correction

When a finding maps cleanly onto an interview question, the skill offers to re-run just that step instead of forcing a full restart. Mappings:

| Finding                                  | Re-asks                                  |
| ---------------------------------------- | ---------------------------------------- |
| `ca-bundle-referenced` mismatch          | "Does your network MITM TLS?" + CA path  |
| `vpn-check-present` failure              | "Is VPN required?" + probe URL           |
| `telemetry-kill-switches-exported` gap   | The kill-switch multi-select             |
| `mcp-servers-in-allowlist` mismatch      | MCP picker                               |
| `forbidden-terms-only-in-branding`       | Brand identity (CORP_BRAND, slug)        |

The user can also reply `skip` to acknowledge the finding without changing config — useful for P2s that are out of scope for this iteration. The acknowledgement is recorded in the JSON sidecar as `"acknowledged": true` so audits in CI don't re-flag it forever.

---

## 7. Audit Report File

Every run writes two artifacts under the launcher install dir:

- `<install_dir>/audit-report.md` — human-readable markdown. Header has score `X/Y`, then a table of all checks, then a section per failing check with file:line evidence. This is the file you attach to the cyber-review ticket.
- `<install_dir>/audit-report.json` — machine-readable sidecar with the same data. Schema:
  ```json
  {
    "launcher_dir": "build/acme-copilot",
    "config_path":  "examples/configs/acme.json",
    "score": 13, "total": 15, "failures": 2,
    "checks": [
      {"name": "ca-handling", "passed": false, "details": ["..."], "severity": "P1"}
    ]
  }
  ```

The JSON is what CI parses. The markdown is what humans read.

---

## 8. CI Integration

Wire the audit into GitHub Actions so a rendered bundle can't merge without passing the same checks the skill ran locally:

```yaml
# .github/workflows/launcher-audit.yml
name: launcher-audit
on:
  pull_request:
    paths:
      - "build/**"
      - "examples/configs/**"
jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Render launcher
        run: |
          python scripts/generate.py \
            --config examples/configs/acme.json \
            --out build/acme-copilot
      - name: Run self-audit (strict)
        run: |
          python scripts/audit-launcher.py \
            --launcher-dir build/acme-copilot \
            --config examples/configs/acme.json \
            --output build/acme-copilot/audit-report.md \
            --strict
      - name: Upload report
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: audit-report
          path: build/acme-copilot/audit-report.*
```

`--strict` makes the exit code equal to the number of failing checks (capped at 125), so the job fails when anything below P2 regresses. Pair with a branch protection rule on `launcher-audit` and the bundle can't merge with open P0/P1 findings.

For platforms running GitLab or Jenkins, the same command works — only the YAML wrapper changes.
