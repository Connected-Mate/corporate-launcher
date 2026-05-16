#!/usr/bin/env bash
# =============================================================================
# ${CORP_NAME} — Cline native usage adapter
# Powered by ${CORP_POWERED_BY}
#
# Cline does NOT route through the strip-proxy when its provider is
# Bedrock-direct, OpenAI-direct, Anthropic-direct, Vertex-direct, etc.
# (anything that is not a LiteLLM-shaped OpenAI-compatible gateway we
# control). To keep the cost ledger complete, this adapter parses the
# extension's own conversation logs and emits one event per API request
# into /tmp/${CORP_SLUG}-usage.jsonl, using the same schema as
# strip-proxy.js so cost-tracker.py treats it identically.
#
# Storage layout (saoudrizwan.claude-dev/tasks/):
#   <globalStorage>/tasks/<task-id>/
#     api_conversation_history.json   # full Anthropic-shaped messages
#     ui_messages.json                # UI events incl. api_req_started
#     task_metadata.json              # model id + timing
#
# Sources:
#   https://github.com/cline/cline (extension repo)
#   https://docs.cline.bot/troubleshooting/task-history-recovery
#   ExtensionMessage.ts -> ClineApiReqInfo {tokensIn, tokensOut,
#                                           cacheReads, cacheWrites, cost}
#
# We read ui_messages.json because each "api_req_started" event already
# carries the figures the UI displays (tokensIn / tokensOut / cacheReads /
# cacheWrites / cost) without us having to re-aggregate Anthropic-shaped
# usage objects nested inside api_conversation_history.json. The model
# id is read from task_metadata.json — fall back to "unknown" if the
# extension hasn't written it yet.
#
# Privacy: we only emit {ts, model, usage, cost, session, source}. We
# never read message text, tool calls, file paths, or any user content.
#
# Lifecycle: the Cline launcher trap-EXITs the PID we daemonise here;
# this script must not survive its parent.
#
# Env in:
#   ${CORP_SLUG_UPPER}_SESSION_ID    optional, stamps each event for --cost session
#   ${CORP_SLUG_UPPER}_USAGE_LOG     override ledger path (default /tmp/${CORP_SLUG}-usage.jsonl)
#   CLINE_ADAPTER_POLL_SECONDS       default 5 (used when fswatch/inotifywait absent)
#   CLINE_ADAPTER_VERBOSE            1 for stderr breadcrumbs
# =============================================================================

set -u

CORP_SLUG="${CORP_SLUG}"
CORP_SLUG_UPPER="${CORP_SLUG_UPPER}"
USAGE_LOG="$\{${CORP_SLUG_UPPER}_USAGE_LOG:-/tmp/${CORP_SLUG}-usage.jsonl\}"
SEEN_FILE="/tmp/${CORP_SLUG}-cline-seen.txt"
SESSION="$\{${CORP_SLUG_UPPER}_SESSION_ID:-\}"
POLL_SECONDS="$\{CLINE_ADAPTER_POLL_SECONDS:-5\}"
VERBOSE="$\{CLINE_ADAPTER_VERBOSE:-0\}"

# tpl: pricing.json lives next to the cost-tracker; if absent, falls back
# tpl: to Cline's own .cost estimate from ui_messages.json (which uses
# tpl: list prices — fine for tenants who have no negotiated rate).
SCRIPT_DIR="$(cd "$(dirname "$\{BASH_SOURCE[0]\}")" && pwd)"
PRICING_FILE="$SCRIPT_DIR/pricing.json"

vlog() { [ "$VERBOSE" = "1" ] && printf '[cline-adapter] %s\n' "$*" >&2 || true; }

# tpl: ---------------------------------------------------------------------
# tpl: Parent-watchdog. When the launcher opens an IDE it returns
# tpl: immediately and the EXIT trap fires; but if the user simply runs
# tpl: `${CORP_SLUG}` interactively the trap also fires on Ctrl-C. To be
# tpl: defensive against detached invocations we also watch a PID.
# tpl: ---------------------------------------------------------------------
WATCH_PID="$\{ADAPTER_PARENT_PID:-\}"
if [ -n "$WATCH_PID" ]; then
    (
        while kill -0 "$WATCH_PID" 2>/dev/null; do
            sleep 3
        done
        kill -- "-$$" 2>/dev/null || kill "$$" 2>/dev/null
    ) &
fi


# tpl: ---------------------------------------------------------------------
# tpl: Discover the active VS Code-family globalStorage paths. Cline lives
# tpl: under <userData>/globalStorage/saoudrizwan.claude-dev/tasks/.
# tpl: We scan every flavour that exists; a developer may have several.
# tpl: ---------------------------------------------------------------------
discover_storage_roots() {
    local roots=()
    case "$(uname -s)" in
        Darwin*)
            for app in "Code" "Code - Insiders" "Cursor" "VSCodium"; do
                local p="$HOME/Library/Application Support/$app/User/globalStorage/saoudrizwan.claude-dev"
                [ -d "$p/tasks" ] && roots+=("$p/tasks")
            done
            ;;
        Linux*)
            for app in "Code" "Code - Insiders" "Cursor" "VSCodium"; do
                local p="$HOME/.config/$app/User/globalStorage/saoudrizwan.claude-dev"
                [ -d "$p/tasks" ] && roots+=("$p/tasks")
            done
            ;;
        MINGW*|MSYS*|CYGWIN*)
            for app in "Code" "Cursor"; do
                local p="$\{APPDATA:-\}/$app/User/globalStorage/saoudrizwan.claude-dev"
                [ -d "$p/tasks" ] && roots+=("$p/tasks")
            done
            ;;
    esac
    [ "$\{#roots[@]\}" -gt 0 ] && printf '%s\n' "$\{roots[@]\}"
}

# tpl: ---------------------------------------------------------------------
# tpl: Emit a single canonical JSONL entry. Done in python so we don't
# tpl: hand-roll JSON escaping in shell (the model id can contain colons,
# tpl: slashes, etc. depending on the provider).
# tpl: ---------------------------------------------------------------------
emit_entry() {
    local ts_iso="$1" model="$2" in_tok="$3" out_tok="$4" cr_tok="$5" cw_tok="$6" fallback_cost="$7" task_id="$8"

    python3 - "$ts_iso" "$SESSION" "$model" "$in_tok" "$out_tok" "$cr_tok" "$cw_tok" "$fallback_cost" "$task_id" "$USAGE_LOG" "$PRICING_FILE" <<'PY'
import json, os, sys
(ts, sess, model, i, o, cr, cw, fallback, task_id, log_path, pricing_path) = sys.argv[1:]
i, o, cr, cw = (int(x or 0) for x in (i, o, cr, cw))

# tpl: cost recomputation — pricing.json wins, Cline's own estimate is
# tpl: the fallback (it uses list prices, not corporate rates).
cost = None
try:
    with open(pricing_path) as fh:
        pricing = json.load(fh)
    p = pricing.get(model)
    if not p:
        for k, v in pricing.items():
            if k in model or model in k:
                p = v
                break
    if p:
        # tpl: pricing.json uses either *_per_1m or short keys — accept both.
        ipx = p.get("input", p.get("input_per_1m", 0))
        opx = p.get("output", p.get("output_per_1m", 0))
        crp = p.get("cache_read", p.get("cache_read_per_1m", 0))
        cwp = p.get("cache_write", p.get("cache_write_per_1m", 0))
        cost = (i/1e6)*ipx + (o/1e6)*opx + (cr/1e6)*crp + (cw/1e6)*cwp
except (OSError, ValueError, json.JSONDecodeError):
    cost = None

if cost is None:
    try:
        cost = float(fallback or 0)
    except ValueError:
        cost = 0.0

entry = {
    "ts": ts,
    "session": sess or task_id,
    "model": model,
    "usage": {
        "input_tokens": i,
        "output_tokens": o,
        "cache_read_input_tokens": cr,
        "cache_creation_input_tokens": cw,
    },
    "cost": cost,
    "source": "cline-adapter",
}
with open(log_path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(entry, separators=(",", ":")) + "\n")
PY
}

# tpl: ---------------------------------------------------------------------
# tpl: One pass over a single task directory. Idempotent via $SEEN_FILE
# tpl: keyed on "<task-id>:<ts-ms>".
# tpl: ---------------------------------------------------------------------
process_task() {
    local task_dir="$1"
    local ui="$task_dir/ui_messages.json"
    local meta="$task_dir/task_metadata.json"
    local task_id
    task_id="$(basename "$task_dir")"

    [ -r "$ui" ] || return 0
    command -v jq >/dev/null 2>&1 || { vlog "jq missing — skip $task_id"; return 0; }

    # tpl: Pick the latest model id mentioned anywhere in task_metadata.json.
    # tpl: Cline writes this as either model_id, apiHandlerModel, or model
    # tpl: depending on the schema version.
    local model=""
    if [ -r "$meta" ]; then
        model="$(jq -r '
            (.. | objects | (.api_handler_model? // .apiHandlerModel? // .model_id? // .model?)) // empty
        ' "$meta" 2>/dev/null | grep -v '^null$' | grep -v '^$' | tail -1)"
    fi
    [ -z "$model" ] && model="unknown"

    # tpl: Extract every api_req_started event as TSV:
    # tpl:   <ts-ms>  <tokensIn>  <tokensOut>  <cacheReads>  <cacheWrites>  <cost>
    local rows
    rows="$(jq -r '
        (if type == "array" then .[] else . end)
        | select(.type == "say" and .say == "api_req_started")
        | (try (.text | fromjson) catch {}) as $t
        | [
            (.ts // 0),
            ($t.tokensIn      // 0),
            ($t.tokensOut     // 0),
            ($t.cacheReads    // 0),
            ($t.cacheWrites   // 0),
            ($t.cost          // 0)
          ] | @tsv
    ' "$ui" 2>/dev/null)" || return 0

    [ -z "$rows" ] && return 0

    local emitted=0
    while IFS=$'\t' read -r ts_ms in_tok out_tok cr_tok cw_tok cline_cost; do
        [ -z "$ts_ms" ] && continue
        [ "$ts_ms" = "0" ] && continue
        local marker="$task_id:$ts_ms"
        if grep -Fxq "$marker" "$SEEN_FILE" 2>/dev/null; then
            continue
        fi

        local ts_iso
        ts_iso="$(python3 -c "import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1])/1000, datetime.timezone.utc).isoformat().replace('+00:00','Z'))" "$ts_ms" 2>/dev/null)" || continue
        [ -z "$ts_iso" ] && continue

        emit_entry "$ts_iso" "$model" "$in_tok" "$out_tok" "$cr_tok" "$cw_tok" "$cline_cost" "$task_id" || continue
        printf '%s\n' "$marker" >> "$SEEN_FILE"
        emitted=$((emitted + 1))
    done <<EOF
$rows
EOF

    [ "$emitted" -gt 0 ] && vlog "task $task_id: emitted $emitted event(s)"
}

# tpl: ---------------------------------------------------------------------
# tpl: Full pass over every detected tasks/ root.
# tpl: ---------------------------------------------------------------------
scan_once() {
    local roots
    roots="$(discover_storage_roots)"
    [ -z "$roots" ] && return 0
    while IFS= read -r root; do
        [ -z "$root" ] && continue
        # tpl: -maxdepth 1 -type d -mindepth 1 → only direct task subdirs.
        find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r tdir; do
            process_task "$tdir"
        done
    done <<EOF
$roots
EOF
}

main() {
    touch "$USAGE_LOG" "$SEEN_FILE" 2>/dev/null || {
        vlog "cannot write $USAGE_LOG or $SEEN_FILE — aborting"
        exit 0
    }

    # tpl: --- catch-up pass (events that landed before we started) ---
    vlog "catch-up scan"
    scan_once

    # tpl: --- watch loop ---
    # tpl: fswatch (macOS) / inotifywait (Linux) → event-driven.
    # tpl: Polling fallback at $POLL_SECONDS when neither is installed.
    local roots
    roots="$(discover_storage_roots)"
    if [ -z "$roots" ]; then
        vlog "no Cline storage roots — exiting (catch-up only)"
        exit 0
    fi

    if command -v fswatch >/dev/null 2>&1; then
        vlog "watching with fswatch"
        # shellcheck disable=SC2086
        printf '%s\n' "$roots" | xargs fswatch -l 2 2>/dev/null | while read -r _; do
            scan_once
        done
    elif command -v inotifywait >/dev/null 2>&1; then
        vlog "watching with inotifywait"
        while true; do
            # shellcheck disable=SC2086
            printf '%s\n' "$roots" | xargs -I{} inotifywait -qq -r -e modify,create,close_write "{}" 2>/dev/null || true
            scan_once
        done
    else
        vlog "polling every $\{POLL_SECONDS\}s (no fswatch/inotifywait)"
        while true; do
            sleep "$POLL_SECONDS"
            scan_once
        done
    fi
}

main "$@"
