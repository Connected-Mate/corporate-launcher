# sync-vars drift remediation

## Before

```
templates scanned : 76
vars used         : 193
vars documented   :  75
Undocumented      :  80  (would fail render)
Dead spec         :  20  (documented but unused)
RESULT            : DRIFT
```

## After

```
templates scanned : 81
vars used         : 178
vars documented   : 124
Undocumented      :   0
Dead spec         :   0
Inconsistent      :   0
RESULT            : clean — exit 0
```

## What moved where

- **Section 1 — Identity**: added `CORP_DOMAIN`, `CORP_DOCS_URL`, `CORP_DEFAULT_LANGUAGE`.
- **Section 2 — Provider**: promoted `WRAPPED_CLIS` to a table row, added `UNDERLYING_CLI*`.
- **Section 3 (per-CLI)**: added the full `CX_*` Codex matrix (`CX_PROVIDER_ID`, `CX_APPROVAL_POLICY`, `CX_SANDBOX_MODE`, `CX_REASONING_EFFORT`, `CX_FORCED_LOGIN_METHOD`, `CX_NODE_MIN_VERSION`, `CX_PROXY_WARNING`, `CX_FAST_MODEL`), `GM_AUTH_ENFORCED_TYPE` / `GM_SANDBOX_MODE` / `GM_TOOLS_EXCLUDE_JSON`, the `LLM_*` block (`LLM_TOKEN_URL`, `LLM_VERIFY_SSL`, `LLM_BACKEND`, `LLM_CONTINUE_PROVIDER`, `LLM_PROVIDER_ID`, `LLM_WEAK_MODEL`), and `CC_CLI_NAME`.
- **Section 4 — Network**: added `VPN_CLIENT_NAME`, `VPN_PROFILE_NAME`, `CA_FILTER_EXTRA`, `CORP_CA_ORG`, `CORP_CA_BUNDLE_PATH`, `CORP_CLIENT_CERT_PATH`, `CORP_CLIENT_KEY_PATH`, `CORP_HTTPS_PROXY`, `CORP_NO_PROXY`.
- **Section 5 — Cyber**: added `CORP_RULES_FILE`, `CORP_SECRET_MANAGER`, `RSSI_CLEARANCE_REF`, `SSO_PROVIDER`, `TOKEN_PORTAL_URL`, `TOKEN_TTL_DAYS`. Stripped the dead `BLOCK_*` / `*_ENABLED` / `CYBER_RULES_FILE` rows (still consumed by `interview.py` for branching but not substituted in templates).
- **Section 6 — Branding**: added `CORP_BRAND_ANSI`. Removed `BRANDING_SYSTEM_PROMPT` (dead).
- **Section 7 — Install layout**: added `NODE_VERSION_MIN`, `PYTHON_VERSION_MIN`, `PROVIDER_KIND`. Removed `BIN_PATH` / `INCLUDE_UNINSTALL` rows (dead at template level).
- **Section 8 — Skills bundle**: added `SKILLS_BUNDLE_REF`. Removed dead `SKILLS_MODE` / `SKILLS_GIT_REF` rows; kept their behaviour in prose.
- **Section 9 — Distribution**: added `DIST_DEFAULT_BRANCH`, `DIST_GIT_REF`, `DIST_S3_BUCKET`, `CORP_ORG_GH`, `INTERNAL_DOCS_URL`, `INTERNAL_NPM_MIRROR_URL`.
- **NEW Section 10 — Runtime / derived**: `CORP_API_KEY`. Documented as a runtime var, not asked at interview. The earlier `revoke-token.sh` runtime locals (`USER_EMAIL`, `ADMIN_TOKEN`, `OPERATOR`, `REASON`, `REQUEST_ID`, `SCOPE`, `STATUS`, `TIMESTAMP`) were neutralised at the template level (escaped `$\{VAR\}`) by an earlier pass, so they are intentionally left out of the table and only mentioned in prose.
- **NEW Section 11 — Feature-specific**: `GATEWAY_ADMIN_API`, `GATEWAY_BACKEND`, `GATEWAY_ADMIN_TOKEN_ENV` (revoke-token); `NEXUS_*`, `ARTIFACTORY_*`, `AWS_PROFILE` (tarball uploaders); `CORP_*_CONTACT`, `CORP_SECURITY_EMAIL`, `CORP_AUDIT_*` (private-git INTERNAL.md).
- **Cline extras** (`CLINE_TARGET_IDES`, `CLINE_AUTO_APPROVE`, `CLINE_DISABLE_MCP_MARKETPLACE`): converted from a table to a bullet list because they drive `interview.py` branching only and are not substituted into any `.tpl`.

## Example config

`examples/configs/acme-claude-litellm.json` was extended with all genuinely interview-required vars (~30 new keys) so `python3 scripts/generate.py --config examples/configs/acme-claude-litellm.json` no longer trips an `UnresolvedVariable`.

## Defensive checks

Before deleting any var I ran `grep -rE '\$\{VAR\}' templates/` to confirm zero `.tpl` occurrences. `BIN_PATH`, `BRANDING_SYSTEM_PROMPT`, `CYBER_RULES_FILE`, `GM_FORCE_VERTEX`, `BLOCK_VOICE_MODE`, `BLOCK_FEEDBACK_CMDS`, `CC_FALLBACK_URL`, `CC_AUTH_MODEL`, `CC_BEDROCK_REGION`, `CC_VERTEX_*`, `LLM_OPENAI_AUTH`, `COST_TRACKING_ENABLED`, `PROMPT_FILTER_ENABLED`, `BLOCK_TELEMETRY`, `BLOCK_AUTO_UPDATE`, `INCLUDE_UNINSTALL`, `PROXY_REQUIRE_AUTH`, `SKILLS_MODE`, `SKILLS_GIT_REF` all came back empty for `${VAR}` substitution; they survive in scripts/interview.py only.
