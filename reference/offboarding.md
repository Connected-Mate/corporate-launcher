# Offboarding — revoking a colleague's gateway token

When the RSSI audits an enterprise AI deployment, the first question is rarely "how do you store the token?" — it's **"how fast can you revoke it when someone leaves?"** This document describes the offboarding flow shipped with every launcher.

---

## Token lifecycle

1. **Install** — the colleague runs `install.sh`. The wrapper prompts once for an API key fetched from the corporate portal and stores it in the OS keychain (macOS Keychain / Windows Credential Manager / libsecret / chmod-600 fallback — see `templates/shared/secrets-store.sh.tpl`).
2. **Use** — every CLI call (`Claude Code`, `Aider`, etc.) reads the key from the keychain and sends it to `${GATEWAY_URL}` as a bearer token.
3. **Audit** — every request is logged on the gateway with subject, model, token-hash and timestamp.
4. **Revoke** — when the user departs, the admin invalidates the token at the gateway. Local copies on the user's machine become useless: the gateway returns `401 Unauthorized` on the next call.

The local copy on the laptop is **not** the source of truth. The gateway is. Revoking server-side is enough — but wiping the laptop is still recommended (see "Pitfalls").

---

## The offboarding flow

```
HR signals departure
        │
        ▼
[IAM event: Okta deprovision / BambooHR webhook / manual ticket]
        │
        ▼
admin@security runs:
   bash revoke-token.sh --user alice@acme.fr --scope all --reason "left 2026-05-15"
        │
        ▼
Gateway invalidates the token
        │
        ▼
   Subsequent CLI calls → 401 Unauthorized
        │
        ▼
JSON event shipped to SIEM (Splunk / Sentinel / Chronicle)
        │
        ▼
(Optional) MDM remote-wipes the keychain entry on the laptop
```

Total time from HR signal to revocation: **target < 15 minutes**.

---

## Backend differences

| Backend | What `revoke-token.sh` does | Granularity |
|---|---|---|
| **LiteLLM** | `POST /key/delete` after `GET /user/info?user_id=…` | per-key, immediate |
| **Azure OpenAI** | `az apim subscription delete` (per-user APIM subscription) | per-subscription, ~30s propagation |
| **Vertex AI** | `gcloud projects remove-iam-policy-binding roles/aiplatform.user` + delete user-owned SA keys | per-IAM-binding, ~60s propagation |
| **Bedrock** | `aws iam detach-user-policy` + delete access keys with `--scope all` | per-user, immediate |

Bedrock and LiteLLM give the cleanest "kill-switch" experience. Vertex and Azure rely on cloud IAM propagation — plan for up to 2 minutes of grace before the token is fully dead.

---

## Integration with IAM systems

Three integration patterns, ordered by maturity:

1. **Okta SCIM webhook** — on `user.lifecycle.deactivate`, Okta posts to a small Lambda/Cloud Run that runs `revoke-token.sh`. Zero manual step. Recommended for fleets > 200.
2. **BambooHR API poller** — a nightly cron lists employees with `status=Terminated` since the last run and pipes each into `revoke-token.sh`. Acceptable for SMBs.
3. **Manual ticket** — IT receives a Jira ticket from HR, the on-call admin runs the script. Document this fallback even if you automate — automation will fail eventually.

The script outputs one JSON line per call (see `templates/shared/revoke-token.sh.tpl`). Pipe it to your SIEM forwarder (`filebeat`, Splunk Universal Forwarder, etc.) by tailing `${INSTALL_DIR}/audit.log`.

---

## Remote-wiping the local keychain (optional)

Server-side revocation is sufficient. But for high-sensitivity roles, MDM can also delete the local copy. Example Jamf script:

```bash
#!/bin/bash
# Run via Jamf Self Service or a "user removed" policy.
TARGET_USER="$1"
sudo -u "$TARGET_USER" security delete-generic-password \
    -s "${CORP_SLUG}" -a "$TARGET_USER" 2>/dev/null || true
rm -f "/Users/$TARGET_USER/.${CORP_SLUG}.conf"
```

Intune / Workspace ONE have equivalent scripts. Trigger them via the same lifecycle event that runs `revoke-token.sh`.

---

## Pitfalls

- **Stale tokens in long-running processes** — a `claude` session started before revocation may continue to work until the next gateway call. Enforce a **max token TTL of 7 days** at the gateway (LiteLLM `duration` field, Azure APIM expiry, Vertex SA key rotation). The CLI re-prompts at expiry and the user, now gone, never re-authenticates.
- **MCP server tokens** — if the launcher pre-configures MCP servers (`reference/skills-bundle.md`), those servers may hold their own credentials (Jira PAT, Confluence token). `--scope all` does **not** revoke those — open a separate ticket per MCP integration.
- **Cached SSO cookies** — Vertex AI via `gcloud auth application-default login` leaves credentials in `~/.config/gcloud/`. The MDM wipe script must clear that path too.
- **Shared workstations** — if the user shared their laptop with a colleague (lab machine, training PC), revoke and re-issue the token for the remaining user.
