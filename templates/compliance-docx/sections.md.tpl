# tpl: This markdown is converted to a .docx by scripts/build-compliance-docx.py.
# tpl: All `${VAR}` placeholders are substituted from answers.json + derived ctx.
# tpl: Lines starting with `# tpl:` are stripped before rendering.
# tpl: Keep heading depth (#, ##) consistent — the docx builder maps depth to Word styles.

# ${CORP_NAME} — Corporate AI Launcher · Compliance file

Sent to: ${CYBER_AUTHORITY}
Date: ${DIST_GENERATED_AT}
Author: the developer who deployed the launcher
Version: ${CORP_LAUNCHER_VERSION}

---

## 1. Executive summary

${CORP_NAME} is an internal AI coding assistant for ${CORP_ORGANIZATION}, powered by ${CORP_POWERED_BY}. The launcher wraps ${UNDERLYING_CLI} so every AI call is routed to the contracted gateway at ${CC_PRIMARY_URL} (${CC_BACKEND}), with the corporate cyber baseline applied.

The launcher is a thin, auditable shim. It does not modify the wrapped CLI binary: it only sets process-scoped environment variables, injects the corporate CA bundle, and registers a pre-tool hook (`cyber-guard`) that intercepts destructive commands before they reach the user's shell. All upstream telemetry endpoints are disabled via documented kill switches, and the assistant identity is locked to ${CORP_NAME} / ${CORP_POWERED_BY} through a non-negotiable system-prompt prefix loaded from `${CORP_RULES_FILE}`.

This document is the compliance dossier submitted to ${CYBER_AUTHORITY} ahead of deployment. It maps each control to a concrete mitigation in the generated artefacts so the security team can verify, not just trust, the launcher's behaviour.

---

## 2. Architecture

```
User → Launcher (process-scoped env) → Corporate Gateway (${CC_PRIMARY_URL})
                                       → ${CC_BACKEND} → LLM Provider
```

No direct egress to the LLM vendor's public API. All connections gated behind the corporate VPN (${VPN_REQUIRED}). The launcher refuses to start when the VPN probe (${VPN_PROBE_URL}) is unreachable, so a user disconnected from the corporate network cannot accidentally bypass the gateway by falling back to a default upstream endpoint.

HTTP egress goes through the corporate proxy at ${PROXY_HOST}:${PROXY_PORT}, and TLS is pinned against the corporate CA bundle (${CORP_CA_BUNDLE_PATH}). The wrapped CLI inherits these settings from the launcher's environment only — nothing is written to the user's global shell profile, so uninstalling the launcher fully removes its footprint.

---

## 3. Threat model

| Threat | Mitigation |
|---|---|
| Data leak to vendor | Gateway-only egress + `permissions.deny` rules in the wrapped CLI config |
| Identity confusion | White-label `BRANDING.md`, `FORBIDDEN_TERMS` (${FORBIDDEN_TERMS}) injected into system prompt |
| Telemetry exfiltration | 12+ kill switches exported (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, `DISABLE_BUG_COMMAND`, etc.) |
| Token leak in transit | Bearer in OS keychain, never in CLI args; `chmod 600 ~/.${CORP_SLUG}.conf` fallback |
| Destructive commands | `pre-tool-hook` `cyber-guard` (locked at `chmod 555`, owned by root or installer) |
| MITM | Corporate CA bundle (${CORP_CA_BUNDLE_PATH}); `ACCEPT_TLS_INSPECTION=${ACCEPT_TLS_INSPECTION}` |
| Offboarding | `revoke-token.sh` script + ${SSO_PROVIDER} integration via ${GATEWAY_ADMIN_API} |
| Supply-chain (CLI upgrade) | Upstream CLI pinned to `${UNDERLYING_CLI_PIN}`, auto-update disabled |
| Prompt-injection exfil | `cyber-rules.md` rule set appended to every system prompt; output filter on secrets |
| Audit trail tampering | `audit.log` shipped to ${CORP_AUDIT_SYSTEM} at ${CORP_AUDIT_LOCATION}, append-only |

---

## 4. The 15 cyber controls

The launcher loads `${CORP_RULES_FILE}` into every system prompt. The full text lives alongside this document; the summary below maps each control to its category so the security team can cross-reference against OWASP Top 10 and ANSSI guidance.

1. **HTTP headers** — strict CSP, HSTS, `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`, `X-Frame-Options: DENY`.
2. **Outdated components** — refuse to propose end-of-life libraries (jQuery < 3.5, CKEditor 4, PHP < 8.1).
3. **Cookies** — `HttpOnly` + `Secure` + `SameSite=Strict|Lax`; session expiry ≤ 8h active / 20min idle.
4. **TLS** — only 1.2/1.3, only ECDHE, RSA ≥ 2048 or ECDSA P-256+.
5. **XSS** — escape interpolated values; ban `innerHTML`, `eval`, `new Function`, `setTimeout(string)`.
6. **SQL injection** — parameterized queries only; never string-concat user input.
7. **Authentication** — lock after 5 failed attempts; generic error message ("invalid credentials").
8. **Sessions** — server-side only; never `localStorage` / `sessionStorage` for session tokens.
9. **Secrets** — never inline; always read from env or ${CORP_SECRET_MANAGER}.
10. **Logging** — never log secrets, tokens, PII, or full request bodies.
11. **Crypto** — AES-256-GCM, ChaCha20-Poly1305, Argon2id / scrypt / bcrypt only. No MD5/SHA-1 for security.
12. **Input validation** — allowlist, server-side; never trust client-side checks alone.
13. **Dependencies** — pin exact versions; check for known CVEs before suggesting.
14. **Errors** — never expose stack traces to end users; log server-side only.
15. **Identity lock** — assistant always answers as ${CORP_NAME} powered by ${CORP_POWERED_BY}; never as ${FORBIDDEN_TERMS}.

---

## 5. Network perimeter

- **VPN required:** ${VPN_REQUIRED}
- **VPN client / profile:** ${VPN_CLIENT_NAME} / ${VPN_PROFILE_NAME}
- **VPN probe:** ${VPN_PROBE_URL}
- **Corporate proxy:** ${PROXY_HOST}:${PROXY_PORT}
- **NO_PROXY list:** ${NO_PROXY_LIST}
- **Custom CA bundle:** ${CORP_CA_BUNDLE_PATH} (auto-extract: ${CA_DETECT_AUTO})
- **Corporate root `O=`:** ${CORP_CA_ORG}
- **mTLS client cert:** ${CORP_CLIENT_CERT_PATH}
- **mTLS client key:** ${CORP_CLIENT_KEY_PATH}
- **TLS inspection accepted:** ${ACCEPT_TLS_INSPECTION}
- **Effective `https_proxy`:** ${CORP_HTTPS_PROXY}
- **Effective `NO_PROXY`:** ${CORP_NO_PROXY}

The launcher refuses to fall back to `NODE_TLS_REJECT_UNAUTHORIZED=0` unless `ACCEPT_TLS_INSPECTION=yes` is explicitly set at install time, so an unconfigured CA bundle fails closed rather than degrading silently to an insecure handshake.

---

## 6. Data classification

- **Default treatment:** every prompt and every file read by the assistant is classified **Internal — Confidential** by default.
- **PII expectation:** no PII expected in source code; ${CORP_DPO_CONTACT} is notified when the launcher is deployed in a context that may process personal data.
- **Prompt filter blocks:** API keys, private keys, AWS/GCP/Azure credentials, JWTs, payment card numbers, government IDs.
- **Audit trail:** `${INSTALL_DIR}/audit.log` (append-only, `chmod 600`) plus JSONL stream to ${CORP_AUDIT_SYSTEM} at ${CORP_AUDIT_LOCATION}.
- **Retention:** managed by the SIEM team; the launcher itself does not delete or rotate `audit.log`.
- **Cost ledger:** measured in ${COST_CURRENCY}; per-user totals are visible only to ${CORP_INTERNAL_CONTACT}.

---

## 7. Bundled skills

- **Total skills bundled:** ${SKILLS_COUNT}
- **MCP servers pre-configured:** ${MCP_SERVERS_COUNT}
- **Skills source:** ${SKILLS_MODE} (${SKILLS_PRESETS} / ${SKILLS_GIT_URL} / ${SKILLS_LOCAL_PATH})
- **Skills release pin:** ${SKILLS_BUNDLE_REF}
- **Skills install path:** ${INSTALL_DIR}/skills/

The full enumerated list is generated from the contents of `${INSTALL_DIR}/skills/` at build time and shipped alongside this document as an appendix. Every bundled skill is loaded from the local filesystem — the launcher never fetches a skill at runtime, so the security team can audit the static set rather than chase moving network sources.

---

## 8. Offboarding plan

1. HR signal (departure ticket) → ${CORP_INTERNAL_CONTACT} runs `revoke-token.sh --user <email>` against ${GATEWAY_ADMIN_API}.
2. Gateway (${GATEWAY_BACKEND}) invalidates the personal token → every subsequent call from the departing user returns HTTP 401.
3. ${SSO_PROVIDER} group membership is removed → the user can no longer mint a fresh token from ${TOKEN_PORTAL_URL}.
4. Optional MDM script wipes the keychain entry and removes `${INSTALL_DIR}` from the user's machine.
5. Audit trail (last ${TOKEN_TTL_DAYS} days minimum) is preserved in ${CORP_AUDIT_SYSTEM} per retention policy.
6. Incident contact for revocation failures: ${CORP_INCIDENT_CONTACT}; security mailbox: ${CORP_SECURITY_EMAIL}.

---

## 9. Sign-off

| Role | Name | Date |
|---|---|---|
| ${CYBER_AUTHORITY} (RSSI / CISO) | ____________________ | __________ |
| Developer who deployed the launcher | ____________________ | __________ |
| Data Protection Officer (if PII processing) | ____________________ | __________ |
| Procurement (vendor renewal) | ${CORP_PROCUREMENT_CONTACT} | __________ |

Clearance reference: ${RSSI_CLEARANCE_REF}
Support contact: ${CORP_SUPPORT_CONTACT}
Docs landing: ${CORP_DOCS_URL}
