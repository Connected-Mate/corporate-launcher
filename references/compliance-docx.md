# Compliance .docx generator

Produces the polished Word document the developer sends to their corporate security office (RSSI / CISO / DPO / ANSSI correspondent) to clear the white-labeled launcher for internal distribution.

Generator: `scripts/build-compliance-docx.py`
Template: `templates/compliance-docx/sections.md.tpl`
Required package: `pip install python-docx` (stdlib only otherwise; Python 3.10+).

---

## 1. What it produces

A single `.docx` file (default name: `compliance.docx`) styled with corporate-grade defaults:

- Calibri base, dark-blue accent (`#0B3D91`), gray body text.
- Centered cover page with org name, tagline, prepared-for line, launcher version, date, optional clearance reference.
- Native Word **Table of Contents** field (auto-refreshes on `right-click → Update Field`).
- Footer on every page: `<CORP_NAME> — Compliance dossier — Powered by <CORP_POWERED_BY>`.
- Tables styled with `Light Grid Accent 1` / `Light List Accent 1`, header rows shaded `#0B3D91`.
- ASCII data-flow diagram rendered in Consolas inside section 2.

The file is **ready to send to the RSSI without manual editing**. The only fields a human fills are the four sign-off cells in section 11 (Name, Role, Date, Signature). Open in Word, refresh TOC field, hand it over.

---

## 2. Sections (10 + cover + TOC + appendix)

Cover page and Table of contents come first, then:

1. **Executive summary** — what the launcher is, which CLIs it wraps, which gateway it routes to, who the dossier is prepared for.
2. **Architecture** — ASCII diagram (User → Launcher → Corp Gateway → LLM Provider) + gateway URL + NO_PROXY scope.
3. **Threat model** — six-row table: data leak to vendor, telemetry exfiltration, vendor lock-in / identity drift, unauthorized egress, credential leak, insecure code generation.
4. **Cyber controls applied** — the 15 controls extracted verbatim from `templates/shared/cyber-rules.md.tpl` (HTTP headers, outdated components, cookies, TLS, XSS, SQLi, auth, sessions, password hashing, logging, GDPR/CNIL, forbidden primitives, input validation, secrets, forbidden patterns). Each with rationale.
5. **Network perimeter** — VPN profile, VPN probe, proxy, NO_PROXY list, CA bundle, CA org issuer, TLS inspection flag, internal npm mirror.
6. **Data classification** — default = Internal — Confidential, PII expectation, prompt filter status, secret manager, DPO contact, applicable regimes (GDPR, CNIL, internal charter).
7. **Telemetry posture** — kill-switch table (analytics, auto-update, feedback commands, voice mode, forbidden vendor terms). Cites `scripts/smoke-test.sh` as test evidence. **If `--audit-report` is provided, the audit findings are embedded as section 10 — see below.**
8. **Audit log** — sink system, sink location, events captured (metadata only, no payloads), retention, access control, PII-in-logs (None), cost-tracking flag.
9. **Offboarding plan** — five-bullet revocation path: SSO deactivation → gateway admin API token revocation → token portal stops issuing → local launcher returns 401 → SOC out-of-band path for lost laptops.
10. **Pre-submission audit findings** *(optional — only rendered when `--audit-report` is passed)* — severity / check / detail table populated from the JSON output of `scripts/audit-launcher.py`.
11. **Sign-off** — paragraph stating the RSSI cleared the version, then a 4-row Name / Role / Date / Signature table. Contact line beneath: internal, incident, DPO.

Appendix appended after sign-off: launcher path on disk, distribution mode, repository URL, skills mode, bundled MCP servers (name, URL, trusted flag).

---

## 3. Customization

Branding and tone live in `templates/compliance-docx/sections.md.tpl` — a markdown skeleton with `${VAR}` placeholders consumed from `config.json` + the derived context.

Common edits:

- **Section text** — edit headings or rephrase paragraphs directly in the template. The Python generator mirrors the structure; if you reorder or rename a section in the template, mirror the change in the matching `section_*` function in `scripts/build-compliance-docx.py`.
- **Accent color** — change `ACCENT = RGBColor(0x0B, 0x3D, 0x91)` near the top of the script (the soft variant and table header fill `0B3D91` follow it).
- **Extra rows in a section** — append to the relevant Python list (e.g. `threats`, `switches`, or the `_kv_row(...)` calls in `section_network_perimeter`).
- **New section** — write a `section_my_thing(doc, ctx)` function and slot it into `build_document()` between the existing calls.

The 15 cyber controls are baked into the script as `CYBER_CONTROLS` so the dossier matches `templates/shared/cyber-rules.md.tpl` line-for-line. Update both together.

---

## 4. Required Python package

```
pip install python-docx
```

The script detects the missing dependency at import time and exits with a clear message:

```
error: python-docx is not installed.
       install it with:  pip install python-docx
```

No other third-party dependency. Pure stdlib otherwise (`argparse`, `json`, `pathlib`, `datetime`).

---

## 5. Usage

### Auto-invoked (default path)

When the developer answers **yes** to the interview question *"Generate the compliance .docx for your RSSI?"*, `scripts/generate.py` calls the builder at the end of the launcher flow and drops `compliance.docx` next to `config.json`.

### Manual

```bash
python3 scripts/build-compliance-docx.py \
    --config config.json \
    --launcher-dir ~/.local/share/<slug> \
    --out compliance.docx
```

With audit findings embedded:

```bash
python3 scripts/audit-launcher.py \
    --launcher-dir ~/.local/share/<slug> \
    --report audit.json

python3 scripts/build-compliance-docx.py \
    --config config.json \
    --launcher-dir ~/.local/share/<slug> \
    --audit-report audit.json \
    --out compliance.docx
```

Exit codes:

- `0` — wrote the file.
- `2` — config file missing or malformed.
- A missing `--audit-report` is a **warning**, not a fatal error; the section is simply skipped.

---

## 6. Localization

Single language for now (**English**). The structure is deliberately translation-friendly:

- All user-visible strings are concentrated in `section_*` functions inside the script and inside `sections.md.tpl`.
- No string is built by token-concatenation inside a loop; sentences are one f-string each, so a translator replaces one line at a time.
- The 15 cyber-control descriptions in `CYBER_CONTROLS` are the largest translation surface (~30 lines).

A French translation (target audience: RSSI ACME / ANSSI correspondents) is the planned next variant. When it lands it will be a second template file (`sections.fr.md.tpl`) selected via a `--lang` flag.

---

## 7. Audit report integration

If `--audit-report path/to/report.json` is supplied, the JSON is loaded and `section_audit_findings` renders a three-column table (Severity / Check / Detail) as **section 10** of the dossier.

Expected JSON shape (either key works):

```json
{
  "findings": [
    { "severity": "warn", "check": "telemetry", "detail": "DISABLE_BUG_COMMAND not exported" },
    { "severity": "info", "check": "ca-bundle", "detail": "Corporate CA detected at /etc/ssl/corp.pem" }
  ]
}
```

Each finding object accepts `check` or `id`, `detail` or `message`. Missing fields render as empty cells, not errors. If `findings` is empty the section prints *"No findings — all checks passed."* in italic.

A malformed audit JSON file is downgraded to a warning on stderr and skipped — the dossier still builds.

---

## 8. Recommended workflow

1. **Run the skill** — `corporate-launcher` interview → `scripts/generate.py` writes the launcher tree.
2. **Auto-generate the .docx** — the interview's last question opts you in; the builder runs and emits `compliance.docx` beside the launcher.
3. **Open in Word** — refresh the TOC field (`right-click → Update Field`), skim the 11 sections, add any custom sign-offs your org requires (procurement, legal, DPO).
4. **Send to the RSSI** — attach the .docx plus the launcher tree (or the dist artifact) to the clearance ticket.
5. **RSSI signs section 11** — name, role, date, signature into the four-row table. Optional: clearance reference goes back into `config.json` as `RSSI_CLEARANCE_REF` for the next regeneration.
6. **File in the compliance register** — store the signed .docx in your corporate compliance vault alongside the launcher version it covers. Re-run the generator for every material change (new CLI wrapped, new MCP server, new gateway endpoint).
