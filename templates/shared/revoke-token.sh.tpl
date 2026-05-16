#!/usr/bin/env bash
# tpl: ${CORP_NAME} — token revocation script (offboarding)
# tpl: Powered by ${CORP_POWERED_BY}
#
# Usage:
#   bash revoke-token.sh --user alice@acme.fr [--scope all] [--reason "left company"]
#
# Required env:
#   ${GATEWAY_ADMIN_TOKEN_ENV}   admin token (do NOT pass on argv)
#
# Exit codes:
#   0 = revoked (or already revoked)
#   1 = bad args
#   2 = gateway error
#   3 = audit-log write failed
#
# Output: a single JSON line on stdout for SIEM ingestion.

set -euo pipefail

# tpl: -------- defaults injected by the launcher generator --------
GATEWAY_ADMIN_API="${GATEWAY_ADMIN_API}"
GATEWAY_BACKEND="${GATEWAY_BACKEND}"          # tpl: litellm | azure | vertex | bedrock
GATEWAY_ADMIN_TOKEN_ENV="${GATEWAY_ADMIN_TOKEN_ENV}"
INSTALL_DIR="${INSTALL_DIR}"
CORP_SLUG="${CORP_SLUG}"
AUDIT_LOG="${INSTALL_DIR}/audit.log"

# tpl: -------- arg parsing --------
USER_EMAIL=""
SCOPE="token"
REASON="offboarding"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)   USER_EMAIL="$2"; shift 2 ;;
        --scope)  SCOPE="$2";      shift 2 ;;
        --reason) REASON="$2";     shift 2 ;;
        -h|--help)
            sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "ERROR: unknown arg: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$USER_EMAIL" ]]; then
    echo "ERROR: --user <email> required" >&2
    exit 1
fi
if ! [[ "$USER_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "ERROR: invalid email: $USER_EMAIL" >&2
    exit 1
fi
if [[ "$SCOPE" != "token" && "$SCOPE" != "all" ]]; then
    echo "ERROR: --scope must be 'token' or 'all'" >&2
    exit 1
fi

# tpl: load admin token from the named env var — never from argv, never logged
ADMIN_TOKEN="$\{!GATEWAY_ADMIN_TOKEN_ENV:-\}"
if [[ -z "$ADMIN_TOKEN" ]]; then
    echo "ERROR: env var $\{GATEWAY_ADMIN_TOKEN_ENV\} not set (admin token)" >&2
    exit 1
fi

REQUEST_ID="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OPERATOR="$\{SUDO_USER:-$USER\}"

# tpl: -------- backend-specific revocation --------
revoke_litellm() {
    # tpl: LiteLLM exposes /key/info?user_id=… then /key/delete with the key id(s).
    local keys_resp
    keys_resp=$(curl -sS --fail-with-body \
        -H "Authorization: Bearer $\{ADMIN_TOKEN\}" \
        -H "X-Request-ID: $\{REQUEST_ID\}" \
        "$\{GATEWAY_ADMIN_API\}/user/info?user_id=$\{USER_EMAIL\}" 2>&1) || {
            echo "$keys_resp" >&2; return 2; }

    # tpl: extract keys array — requires jq on the admin host
    local key_ids
    key_ids=$(echo "$keys_resp" | jq -r '.keys[]?.token // empty')
    if [[ -z "$key_ids" ]]; then
        echo "INFO: no active keys for $\{USER_EMAIL\}" >&2
        return 0
    fi

    # tpl: bulk delete
    local payload
    payload=$(jq -n --argjson k "$(echo "$key_ids" | jq -R . | jq -s .)" '{keys: $k}')
    curl -sS --fail-with-body \
        -X POST "$\{GATEWAY_ADMIN_API\}/key/delete" \
        -H "Authorization: Bearer $\{ADMIN_TOKEN\}" \
        -H "Content-Type: application/json" \
        -H "X-Request-ID: $\{REQUEST_ID\}" \
        -d "$payload" >/dev/null

    # tpl: optional: unbind from teams
    if [[ "$SCOPE" == "all" ]]; then
        curl -sS \
            -X POST "$\{GATEWAY_ADMIN_API\}/team/member_delete" \
            -H "Authorization: Bearer $\{ADMIN_TOKEN\}" \
            -H "Content-Type: application/json" \
            -d "{\"user_id\":\"$\{USER_EMAIL\}\"}" >/dev/null || true
    fi
    echo "$key_ids" | wc -l | tr -d ' '
}

revoke_azure() {
    # tpl: Azure OpenAI uses resource-level keys (Key1/Key2) — per-user keys come from
    # tpl: APIM subscription keys or Entra ID app registrations. We delete the APIM
    # tpl: subscription tied to the user's Entra object id.
    local sub_id
    sub_id=$(az apim subscription list \
        --resource-group "$\{AZURE_APIM_RG\}" \
        --service-name  "$\{AZURE_APIM_NAME\}" \
        --query "[?ownerId=='$\{USER_EMAIL\}'].name | [0]" \
        -o tsv 2>/dev/null) || return 2

    if [[ -z "$sub_id" || "$sub_id" == "null" ]]; then
        echo "INFO: no APIM subscription for $\{USER_EMAIL\}" >&2
        return 0
    fi

    az apim subscription delete \
        --resource-group "$\{AZURE_APIM_RG\}" \
        --service-name  "$\{AZURE_APIM_NAME\}" \
        --sid "$sub_id" --yes >/dev/null
    echo "1"
}

revoke_vertex() {
    # tpl: Vertex uses service-account keys. Per-user revocation = remove IAM binding
    # tpl: on the project's vertex-ai-user role and delete any user-owned SA keys.
    gcloud projects remove-iam-policy-binding "$\{GCP_PROJECT_ID\}" \
        --member="user:$\{USER_EMAIL\}" \
        --role="roles/aiplatform.user" \
        --quiet >/dev/null 2>&1 || return 2

    # tpl: delete any SA keys the user created (key-rotation hygiene)
    if [[ "$SCOPE" == "all" ]]; then
        gcloud iam service-accounts list \
            --filter="email~^$\{USER_EMAIL%@*\}-.*@$\{GCP_PROJECT_ID\}\\.iam\\." \
            --format="value(email)" 2>/dev/null | while read -r sa; do
            gcloud iam service-accounts delete "$sa" --quiet >/dev/null 2>&1 || true
        done
    fi
    echo "1"
}

revoke_bedrock() {
    # tpl: Bedrock = AWS IAM. Detach the user's policy that grants bedrock:InvokeModel.
    aws iam detach-user-policy \
        --user-name "$\{USER_EMAIL%@*\}" \
        --policy-arn "$\{BEDROCK_USER_POLICY_ARN\}" 2>/dev/null || return 2

    if [[ "$SCOPE" == "all" ]]; then
        # tpl: also delete the user's access keys
        aws iam list-access-keys --user-name "$\{USER_EMAIL%@*\}" \
            --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null | \
            tr '\t' '\n' | while read -r ak; do
                [[ -n "$ak" ]] && aws iam delete-access-key \
                    --user-name "$\{USER_EMAIL%@*\}" --access-key-id "$ak" >/dev/null
            done
    fi
    echo "1"
}

# tpl: -------- dispatch --------
set +e
case "$GATEWAY_BACKEND" in
    litellm) REVOKED_COUNT=$(revoke_litellm); RC=$? ;;
    azure)   REVOKED_COUNT=$(revoke_azure);   RC=$? ;;
    vertex)  REVOKED_COUNT=$(revoke_vertex);  RC=$? ;;
    bedrock) REVOKED_COUNT=$(revoke_bedrock); RC=$? ;;
    *)
        echo "ERROR: unknown backend: $GATEWAY_BACKEND" >&2
        RC=2; REVOKED_COUNT=0
        ;;
esac
set -e

STATUS="revoked"
[[ $RC -ne 0 ]] && STATUS="error"
[[ -z "$\{REVOKED_COUNT:-\}" || "$REVOKED_COUNT" == "0" ]] && STATUS="already_revoked"

# tpl: -------- structured JSON for SIEM --------
JSON=$(cat <<EOF_JSON
{"timestamp":"$\{TIMESTAMP\}","event":"token.revoke","status":"$\{STATUS\}","subject":"$\{USER_EMAIL\}","scope":"$\{SCOPE\}","backend":"$\{GATEWAY_BACKEND\}","operator":"$\{OPERATOR\}","request_id":"$\{REQUEST_ID\}","reason":"$\{REASON\}","revoked_count":$\{REVOKED_COUNT:-0\},"corp":"${CORP_SLUG}"}
EOF_JSON
)

# tpl: emit to stdout (capture from cron / wrapper)
echo "$JSON"

# tpl: append to local audit log (chmod 600, created on first write)
{
    umask 077
    touch "$AUDIT_LOG"
    echo "$JSON" >> "$AUDIT_LOG"
} || {
    echo "ERROR: failed to write audit log: $AUDIT_LOG" >&2
    exit 3
}

exit $RC
