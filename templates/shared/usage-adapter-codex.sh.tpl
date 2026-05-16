#!/usr/bin/env bash
# =============================================================================
# ${CORP_NAME} — Codex CLI native usage adapter
# Powered by ${CORP_POWERED_BY}
#
# Codex CLI is a Rust binary (reqwest) that does NOT honour HTTPS_PROXY
# consistently (upstream issue #4242). When the corporate strip-proxy is
# bypassed — which is the common case for Bedrock and direct-OpenAI
# wirings — usage is invisible to /tmp/${CORP_SLUG}-usage.jsonl.
#
# Luckily Codex writes a complete JSONL rollout of every session under:
#   ~/.codex/sessions/YYYY/MM/DD/rollout-<iso-ts>-<session-id>.jsonl
#
# Schema confirmed by tailing real files (cli_version 0.126+):
#   {"timestamp": ISO8601, "type": "session_meta", "payload": {"id": ...}}
#   {"timestamp": ISO8601, "type": "turn_context",
#     "payload": {"turn_id": ..., "model": "gpt-5.5", ...}}
#   {"timestamp": ISO8601, "type": "event_msg",
#     "payload": {
#       "type": "token_count",
#       "info": {
#         "total_token_usage": {input_tokens, cached_input_tokens,
#                               output_tokens, reasoning_output_tokens,
#                               total_tokens},
#         "last_token_usage":  {... per-turn deltas ...},
#         "model_context_window": int
#       }
#     }}
#
# We emit one event per token_count entry, using last_token_usage (per
# turn) so multiple events from the same session don't double-count.
# Sessions whose info is null (rate-limit pings before any turn) are
# skipped — they carry no usage data.
#
# Sources:
#   https://developers.openai.com/codex/cli/reference
#   https://github.com/openai/codex   (rollout writer)
#   https://ccusage.com/guide/codex/  (third-party schema notes)
#
# Privacy: we only emit {ts, model, usage, cost, session, source}. The
# rollout file also stores prompts, tool calls and code edits — we never
# touch any of that.
#
# Lifecycle: the Codex launcher trap-EXITs this PID; this script must
# not survive its parent.
#
# Env in:
#   ${CORP_SLUG_UPPER}_SESSION_ID    optional, stamps each event for --cost session
#   ${CORP_SLUG_UPPER}_USAGE_LOG     override ledger path (default /tmp/${CORP_SLUG}-usage.jsonl)
#   CODEX_HOME                       default $HOME/.codex
#   CODEX_ADAPTER_POLL_SECONDS       default 5 (used when fswatch/inotifywait absent)
#   CODEX_ADAPTER_VERBOSE            1 for stderr breadcrumbs
# =============================================================================

set -u

CORP_SLUG="${CORP_SLUG}"
CORP_SLUG_UPPER="${CORP_SLUG_UPPER}"
USAGE_LOG="$\{${CORP_SLUG_UPPER}_USAGE_LOG:-/tmp/${CORP_SLUG}-usage.jsonl\}"
SEEN_FILE="/tmp/${CORP_SLUG}-codex-seen.txt"
SESSION="$\{${CORP_SLUG_UPPER}_SESSION_ID:-\}"
POLL_SECONDS="$\{CODEX_ADAPTER_POLL_SECONDS:-5\}"
VERBOSE="$\{CODEX_ADAPTER_VERBOSE:-0\}"
CODEX_HOME="$\{CODEX_HOME:-$HOME/.codex\}"
SESSIONS_DIR="$CODEX_HOME/sessions"

SCRIPT_DIR="$(cd "$(dirname "$\{BASH_SOURCE[0]\}")" && pwd)"
PRICING_FILE="$SCRIPT_DIR/pricing.json"

vlog() { [ "$VERBOSE" = "1" ] && printf '[codex-adapter] %s\n' "$*" >&2 || true; }

# tpl: ---------------------------------------------------------------------
# tpl: Parent-watchdog. The Codex launcher exec()s codex, so the bash
# tpl: EXIT trap is never reached. Instead we ask the adapter to watch
# tpl: a PID and self-terminate when it disappears. The launcher exports
# tpl: ADAPTER_PARENT_PID before spawning us.
# tpl: ---------------------------------------------------------------------
WATCH_PID="$\{ADAPTER_PARENT_PID:-\}"
if [ -n "$WATCH_PID" ]; then
    (
        while kill -0 "$WATCH_PID" 2>/dev/null; do
            sleep 3
        done
        # tpl: parent gone — final scan, then kill our own PG so the
        # tpl: fswatch / inotifywait child also dies.
        kill -- "-$$" 2>/dev/null || kill "$$" 2>/dev/null
    ) &
fi


# tpl: ---------------------------------------------------------------------
# tpl: Process a single rollout JSONL file. All logic is in python because
# tpl: we need stateful scanning (last turn_context.model → following
# tpl: token_count events) and idempotent line-offset tracking.
# tpl: ---------------------------------------------------------------------
process_rollout() {
    local rollout="$1"
    [ -r "$rollout" ] || return 0

    python3 - "$rollout" "$SEEN_FILE" "$USAGE_LOG" "$PRICING_FILE" "$SESSION" "${CORP_SLUG}" <<'PY'
import json, os, sys, hashlib

rollout_path, seen_path, log_path, pricing_path, session_env, corp_slug = sys.argv[1:]

# tpl: --- pricing.json load (best-effort) ---
pricing = {}
try:
    with open(pricing_path) as fh:
        pricing = json.load(fh)
except (OSError, ValueError, json.JSONDecodeError):
    pricing = {}

def price_for(model):
    if not model:
        return None
    p = pricing.get(model)
    if p:
        return p
    for k, v in pricing.items():
        if k in model or model in k:
            return v
    return None

def cost_of(usage, model):
    p = price_for(model)
    if not p:
        return None
    # tpl: support both naming conventions in pricing.json
    ipx = p.get("input", p.get("input_per_1m", 0))
    opx = p.get("output", p.get("output_per_1m", 0))
    crp = p.get("cache_read", p.get("cache_read_per_1m", 0))
    # tpl: Codex doesn't emit cache_creation, only cached_input_tokens
    return (
        (usage.get("input_tokens", 0) / 1e6) * ipx
        + (usage.get("output_tokens", 0) / 1e6) * opx
        + (usage.get("cache_read_input_tokens", 0) / 1e6) * crp
    )

# tpl: --- load seen markers (one per line: "<rollout-basename>:<line-no>") ---
seen = set()
try:
    with open(seen_path) as fh:
        for line in fh:
            seen.add(line.rstrip("\n"))
except FileNotFoundError:
    pass

basename = os.path.basename(rollout_path)
# tpl: Derive a stable session id from the rollout filename (matches the
# tpl: session UUID Codex puts inside session_meta.payload.id).
# tpl: rollout-2026-04-30T20-29-36-019dde26-c781-7af0-bbf9-ca3353614e06.jsonl
sid_from_name = basename.removeprefix("rollout-").removesuffix(".jsonl")
# tpl: strip the leading timestamp (YYYY-MM-DDTHH-MM-SS-) → leaves UUID
parts = sid_from_name.split("-", 6)
session_id = parts[-1] if len(parts) >= 7 else sid_from_name

current_model = None
emitted = 0
new_markers = []
log_fh = open(log_path, "a", encoding="utf-8")

try:
    with open(rollout_path, encoding="utf-8") as fh:
        for line_no, raw in enumerate(fh, start=1):
            marker = f"{basename}:{line_no}"
            if marker in seen:
                continue
            raw = raw.strip()
            if not raw:
                new_markers.append(marker)
                continue
            try:
                evt = json.loads(raw)
            except json.JSONDecodeError:
                new_markers.append(marker)
                continue

            etype = evt.get("type")
            payload = evt.get("payload") or {}

            # tpl: track the active model — turn_context carries it.
            if etype == "turn_context":
                m = payload.get("model")
                if m:
                    current_model = m
                new_markers.append(marker)
                continue

            # tpl: session_meta sometimes carries model_provider; not the
            # tpl: model itself, but useful for source attribution.
            if etype == "session_meta":
                new_markers.append(marker)
                continue

            # tpl: the only event we actually emit on.
            if etype == "event_msg" and payload.get("type") == "token_count":
                info = payload.get("info")
                if not info:
                    # tpl: rate-limit ping with null info — skip silently.
                    new_markers.append(marker)
                    continue
                last = info.get("last_token_usage") or {}
                if not last:
                    new_markers.append(marker)
                    continue

                usage = {
                    "input_tokens":             int(last.get("input_tokens", 0) or 0),
                    "output_tokens":            int(last.get("output_tokens", 0) or 0),
                    "cache_read_input_tokens":  int(last.get("cached_input_tokens", 0) or 0),
                    # tpl: Codex reports reasoning tokens separately; we
                    # tpl: surface them under a dedicated key so cost-tracker
                    # tpl: + dashboard can render them, while keeping the
                    # tpl: canonical input/output fields untouched.
                    "reasoning_output_tokens":  int(last.get("reasoning_output_tokens", 0) or 0),
                }
                # tpl: if everything's zero, the rollout writer flushed a
                # tpl: stale token_count — skip.
                if sum(usage.values()) == 0:
                    new_markers.append(marker)
                    continue

                cost = cost_of(usage, current_model)
                entry = {
                    "ts":      evt.get("timestamp") or "",
                    "session": session_env or session_id,
                    "model":   current_model or "unknown",
                    "usage":   usage,
                    "cost":    cost if cost is not None else 0.0,
                    "source":  "codex-adapter",
                }
                log_fh.write(json.dumps(entry, separators=(",", ":")) + "\n")
                emitted += 1
            new_markers.append(marker)
finally:
    log_fh.close()

# tpl: append-only marker file — every processed line is recorded so a
# tpl: re-scan after a rotation never re-emits.
if new_markers:
    with open(seen_path, "a", encoding="utf-8") as fh:
        for m in new_markers:
            fh.write(m + "\n")

# tpl: VERBOSE breadcrumb to stderr (shell wrapper decides whether to print).
if emitted:
    sys.stderr.write(f"[codex-adapter] {basename}: emitted {emitted} event(s)\n")
PY
}

# tpl: ---------------------------------------------------------------------
# tpl: Full pass over every rollout file in $SESSIONS_DIR.
# tpl: Codex writes the file as the session progresses, so we re-scan
# tpl: known files too (process_rollout is line-level idempotent).
# tpl: ---------------------------------------------------------------------
scan_once() {
    [ -d "$SESSIONS_DIR" ] || return 0
    # tpl: -newer marker? avoid — clock-skew bites. Cheap full scan instead;
    # tpl: process_rollout is line-idempotent.
    find "$SESSIONS_DIR" -type f -name 'rollout-*.jsonl' 2>/dev/null | while IFS= read -r f; do
        process_rollout "$f"
    done
}

main() {
    touch "$USAGE_LOG" "$SEEN_FILE" 2>/dev/null || {
        vlog "cannot write $USAGE_LOG or $SEEN_FILE — aborting"
        exit 0
    }

    if [ ! -d "$SESSIONS_DIR" ]; then
        vlog "no $SESSIONS_DIR — first Codex run will create it. Idling."
        # tpl: still poll: Codex might create the dir mid-session.
    fi

    # tpl: --- catch-up pass ---
    vlog "catch-up scan starting"
    scan_once
    vlog "catch-up scan done"

    # tpl: --- watch loop ---
    if command -v fswatch >/dev/null 2>&1 && [ -d "$SESSIONS_DIR" ]; then
        vlog "watching with fswatch $SESSIONS_DIR"
        fswatch -l 2 "$SESSIONS_DIR" 2>/dev/null | while read -r _; do
            scan_once
        done
    elif command -v inotifywait >/dev/null 2>&1 && [ -d "$SESSIONS_DIR" ]; then
        vlog "watching with inotifywait $SESSIONS_DIR"
        while true; do
            inotifywait -qq -r -e modify,create,close_write "$SESSIONS_DIR" 2>/dev/null || true
            scan_once
        done
    else
        vlog "polling every $\{POLL_SECONDS\}s (no fswatch/inotifywait or no sessions dir yet)"
        while true; do
            sleep "$POLL_SECONDS"
            scan_once
        done
    fi
}

main "$@"
