---
name: compliance-docx
description: Subagent that generates the corporate compliance Word document for RSSI/CISO/DPO review, summarizing the launcher's architecture, threat model, cyber controls, and audit findings. Use during Phase 4.5 when the user opted in via COMPLIANCE_DOCX=yes.
context: fork
allowed-tools: Bash, Read
---

# Compliance DOCX Subagent

## What

Runs `scripts/build-compliance-docx.py` to produce the corporate compliance Word document (`compliance.docx`) intended for RSSI / CISO / DPO sign-off. Returns the absolute output path plus a 3-line content summary (section count, page count, file size).

## Input

- `--config <path>` — corporate launcher config (JSON/YAML) describing the deployment.
- `--launcher-dir <path>` — root directory of the generated launcher; the `.docx` is written there.
- `--audit-report <path>` *(optional)* — prior `/audit` JSON report to embed under section 9 (Audit Findings).

## Workflow

1. **Pre-flight — verify `python-docx`**
   - Run `python3 -c "import docx" 2>&1`.
   - If it fails, abort and tell the user:
     `python-docx is required. Install with: pip install python-docx>=1.1.0` — do **not** attempt a silent install.

2. **Generate the document**
   ```bash
   python3 "${CLAUDE_SKILL_DIR}/scripts/build-compliance-docx.py" \
     --config "<config>" \
     --launcher-dir "<launcher-dir>" \
     --audit-report "<audit-report-or-omit>" \
     --out "<launcher-dir>/compliance.docx"
   ```
   Capture stdout/stderr. Non-zero exit → surface the error verbatim and abort.

3. **Validate the `.docx`**
   - Re-open the file via:
     ```bash
     python3 -c "from docx import Document; d=Document('<out>'); \
       hs=[p.text for p in d.paragraphs if p.style.name.startswith('Heading 1')]; \
       print(len(hs)); print('\n'.join(hs))"
     ```
   - Expected 10 sections (Heading 1):
     1. Executive Summary
     2. Architecture Overview
     3. Data Flows & Boundaries
     4. Threat Model (STRIDE)
     5. Cyber Controls (Corporate Security Office)
     6. Identity, Secrets & Key Management
     7. Logging, Audit & Observability
     8. Privacy & DPO Considerations (RGPD)
     9. Audit Findings
     10. Sign-off & Approval Matrix
   - If any section is missing → **regenerate once** with the same command. If still missing, report the missing headings and abort.

4. **Return**
   - Absolute path of the `.docx`.
   - File size (`ls -lh`), page count (estimated via `python-docx`: paragraph count / 35), section count (must be 10).
   - 3-line summary: `path | sections=10 | size=<N>KB pages≈<N>`.

## Quality bar

- All 10 Heading 1 sections present, in order. Otherwise regenerate, then fail loudly.
- File ≥ 20 KB (smaller = likely empty template).
- No placeholder tokens (`{{...}}`) remaining in the document body.
- If `python-docx` is missing → graceful install instruction, never a stack trace.

## Why fork context

Generating a Word document involves binary scaffolding, raw XML, and verbose validation noise. Forking keeps the main conversation clean — only the final path + 3-line summary bubbles up to the orchestrator.

## References

- Script: `scripts/build-compliance-docx.py`
- Section template: `templates/compliance-docx/sections.md.tpl`
- Triggered by: Phase 4.5 of the corporate-launcher SKILL when `COMPLIANCE_DOCX=yes`.
