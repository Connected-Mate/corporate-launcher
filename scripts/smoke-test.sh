#!/usr/bin/env bash
# smoke-test.sh — one-shot smoke test for the corporate-launcher project.
#
# Usage:
#   bash scripts/smoke-test.sh [--config <path>] [--out <path>] [--keep]
#
# Walks the full happy path: env checks, render tests, dry-run, real render,
# launcher --help, launcher dry-run, sync-vars guard. Exit code = #failures.
#
# Portable: macOS + Linux. No GNU-only flags. No -u (we tolerate missing
# optional vars). set -e is OFF inside step runners so we can capture failures.

set -eo pipefail

# --------------------------------------------------------------------------- #
# Resolve repo root (this script lives in <repo>/scripts/)                    #
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --------------------------------------------------------------------------- #
# Defaults + arg parsing                                                      #
# --------------------------------------------------------------------------- #
CONFIG="$REPO_ROOT/examples/configs/acme-claude-litellm.json"
OUT="/tmp/corp-launcher-smoke"
KEEP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --config) CONFIG="$2"; shift 2 ;;
        --out)    OUT="$2";    shift 2 ;;
        --keep)   KEEP=1;      shift   ;;
        -h|--help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *)
            echo "smoke-test: unknown arg: $1" >&2
            exit 2
            ;;
    esac
done

# --------------------------------------------------------------------------- #
# ANSI colors (only when stdout is a TTY)                                     #
# --------------------------------------------------------------------------- #
if [ -t 1 ]; then
    C_RESET="$(printf '\033[0m')"
    C_BOLD="$(printf '\033[1m')"
    C_RED="$(printf '\033[31m')"
    C_GREEN="$(printf '\033[32m')"
    C_YELLOW="$(printf '\033[33m')"
    C_BLUE="$(printf '\033[34m')"
    C_DIM="$(printf '\033[2m')"
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""
fi

# --------------------------------------------------------------------------- #
# Step bookkeeping                                                            #
# --------------------------------------------------------------------------- #
TOTAL=10
FAILURES=0
declare -a STEP_NAMES
declare -a STEP_STATUS
declare -a STEP_DETAIL

record() {
    # record <idx> <name> <status:OK|FAIL|SKIP> <detail>
    STEP_NAMES[$1]="$2"
    STEP_STATUS[$1]="$3"
    STEP_DETAIL[$1]="$4"
}

header() {
    local idx="$1" total="$2" name="$3"
    printf "\n%s[%d/%d]%s %s%s%s\n" \
        "$C_BLUE" "$idx" "$total" "$C_RESET" "$C_BOLD" "$name" "$C_RESET"
}

ok() {
    local detail="$1"
    printf "  %sOK%s %s%s%s\n" "$C_GREEN" "$C_RESET" "$C_DIM" "$detail" "$C_RESET"
}

fail() {
    local detail="$1"
    printf "  %sFAIL%s %s\n" "$C_RED" "$C_RESET" "$detail"
    FAILURES=$((FAILURES + 1))
}

# Run a command, capture stdout+stderr to a tmp log, return its rc.
# Args: <logfile> <cmd...>
run_capture() {
    local log="$1"; shift
    "$@" >"$log" 2>&1
    return $?
}

# --------------------------------------------------------------------------- #
# Sanity checks                                                               #
# --------------------------------------------------------------------------- #
if [ ! -f "$CONFIG" ]; then
    printf "%sERROR%s: config not found: %s\n" "$C_RED" "$C_RESET" "$CONFIG" >&2
    exit 2
fi

printf "%sCorporate Launcher — Smoke Test%s\n" "$C_BOLD" "$C_RESET"
printf "  repo    : %s\n" "$REPO_ROOT"
printf "  config  : %s\n" "$CONFIG"
printf "  out     : %s\n" "$OUT"
printf "  keep    : %s\n" "$KEEP"

# Fresh out directory.
rm -rf "$OUT"
mkdir -p "$OUT"
LOG_DIR="$OUT/_logs"
mkdir -p "$LOG_DIR"

# Extract slug + uppercase slug from config using python (portable).
SLUG="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['CORP_SLUG'])" "$CONFIG")"
SLUG_UPPER="$(printf '%s' "$SLUG" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"

# --------------------------------------------------------------------------- #
# Step 1 — Python 3.10+                                                       #
# --------------------------------------------------------------------------- #
header 1 "$TOTAL" "Python 3.10+ available"
if command -v python3 >/dev/null 2>&1; then
    PY_VER="$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')"
    PY_OK="$(python3 -c 'import sys; print(1 if sys.version_info >= (3,10) else 0)')"
    if [ "$PY_OK" = "1" ]; then
        ok "python3 $PY_VER"
        record 1 "Python 3.10+"        "OK"   "$PY_VER"
    else
        fail "python3 $PY_VER (need >= 3.10)"
        record 1 "Python 3.10+"        "FAIL" "$PY_VER"
    fi
else
    fail "python3 not found in PATH"
    record 1 "Python 3.10+"        "FAIL" "not found"
fi

# --------------------------------------------------------------------------- #
# Step 2 — Node 18+                                                           #
# --------------------------------------------------------------------------- #
header 2 "$TOTAL" "Node 18+ available"
if command -v node >/dev/null 2>&1; then
    NODE_VER_RAW="$(node --version 2>/dev/null || echo "v0.0.0")"
    NODE_MAJOR="$(printf '%s' "$NODE_VER_RAW" | sed 's/^v//' | cut -d. -f1)"
    if [ -n "$NODE_MAJOR" ] && [ "$NODE_MAJOR" -ge 18 ] 2>/dev/null; then
        ok "node $NODE_VER_RAW"
        record 2 "Node 18+"            "OK"   "$NODE_VER_RAW"
    else
        fail "node $NODE_VER_RAW (need >= 18)"
        record 2 "Node 18+"            "FAIL" "$NODE_VER_RAW"
    fi
else
    fail "node not found in PATH"
    record 2 "Node 18+"            "FAIL" "not found"
fi

# --------------------------------------------------------------------------- #
# Step 3 — pytest tests/test_render.py                                        #
# --------------------------------------------------------------------------- #
header 3 "$TOTAL" "pytest tests/test_render.py -q"
LOG="$LOG_DIR/03-pytest.log"
set +e
( cd "$REPO_ROOT" && python3 -m pytest tests/test_render.py -q ) >"$LOG" 2>&1
RC=$?
set -e
if [ $RC -eq 0 ]; then
    SUM="$(tail -n 1 "$LOG" | tr -d '\r')"
    ok "pytest passed ($SUM)"
    record 3 "pytest test_render"  "OK"   "$SUM"
else
    fail "pytest exited $RC — see $LOG"
    tail -n 20 "$LOG" | sed 's/^/    | /'
    record 3 "pytest test_render"  "FAIL" "rc=$RC"
fi

# --------------------------------------------------------------------------- #
# Step 4 — render.py --tree templates/claude-code --strict                    #
# --------------------------------------------------------------------------- #
header 4 "$TOTAL" "render.py --tree templates/claude-code --strict"
LOG="$LOG_DIR/04-render.log"
RENDER_OUT="$OUT/render-only"
set +e
( cd "$REPO_ROOT" && python3 scripts/render.py \
        --context "$CONFIG" \
        --tree templates/claude-code \
        --out "$RENDER_OUT" \
        --strict ) >"$LOG" 2>&1
RC=$?
set -e
if [ $RC -eq 0 ]; then
    N_FILES="$(find "$RENDER_OUT" -type f 2>/dev/null | wc -l | tr -d ' ')"
    ok "rendered $N_FILES file(s) to $RENDER_OUT"
    record 4 "render.py --strict"  "OK"   "$N_FILES files"
else
    fail "render.py exited $RC — see $LOG"
    tail -n 20 "$LOG" | sed 's/^/    | /'
    record 4 "render.py --strict"  "FAIL" "rc=$RC"
fi

# --------------------------------------------------------------------------- #
# Step 5 — generate.py --dry-run                                              #
# --------------------------------------------------------------------------- #
header 5 "$TOTAL" "generate.py --dry-run"
LOG="$LOG_DIR/05-generate-dry.log"
set +e
( cd "$REPO_ROOT" && python3 scripts/generate.py \
        --config "$CONFIG" \
        --out "$OUT/full" \
        --dry-run ) >"$LOG" 2>&1
RC=$?
set -e
if [ $RC -eq 0 ]; then
    ok "dry-run pipeline clean"
    record 5 "generate --dry-run"  "OK"   "rc=0"
else
    fail "generate.py --dry-run exited $RC — see $LOG"
    tail -n 20 "$LOG" | sed 's/^/    | /'
    record 5 "generate --dry-run"  "FAIL" "rc=$RC"
fi

# --------------------------------------------------------------------------- #
# Step 6 — generate.py real render                                            #
# --------------------------------------------------------------------------- #
header 6 "$TOTAL" "generate.py (real render)"
LOG="$LOG_DIR/06-generate.log"
set +e
( cd "$REPO_ROOT" && python3 scripts/generate.py \
        --config "$CONFIG" \
        --out "$OUT/full" ) >"$LOG" 2>&1
RC=$?
set -e
LAUNCHER="$OUT/full/$SLUG"
if [ $RC -eq 0 ] && [ -f "$LAUNCHER" ]; then
    ok "launcher written: $LAUNCHER"
    record 6 "generate (real)"     "OK"   "$LAUNCHER"
else
    fail "generate.py exited $RC (launcher present: $([ -f "$LAUNCHER" ] && echo yes || echo no)) — see $LOG"
    tail -n 30 "$LOG" | sed 's/^/    | /'
    record 6 "generate (real)"     "FAIL" "rc=$RC"
fi

# --------------------------------------------------------------------------- #
# Step 7 — launcher --help                                                    #
# --------------------------------------------------------------------------- #
header 7 "$TOTAL" "launcher --help"
LOG="$LOG_DIR/07-help.log"
if [ -f "$LAUNCHER" ]; then
    set +e
    bash "$LAUNCHER" --help >"$LOG" 2>&1
    RC=$?
    set -e
    HELP_LINES="$(wc -l <"$LOG" | tr -d ' ')"
    if [ $RC -eq 0 ] && [ "$HELP_LINES" -gt 0 ]; then
        ok "--help printed $HELP_LINES line(s)"
        record 7 "launcher --help"     "OK"   "$HELP_LINES lines"
    else
        fail "launcher --help rc=$RC, lines=$HELP_LINES — see $LOG"
        tail -n 20 "$LOG" | sed 's/^/    | /'
        record 7 "launcher --help"     "FAIL" "rc=$RC"
    fi
else
    fail "launcher missing, skipping"
    record 7 "launcher --help"     "FAIL" "launcher missing"
fi

# --------------------------------------------------------------------------- #
# Step 8 — launcher dry-run env var                                           #
# --------------------------------------------------------------------------- #
header 8 "$TOTAL" "launcher dry-run (${SLUG_UPPER}_DRY_RUN=1)"
LOG="$LOG_DIR/08-dryrun.log"
if [ -f "$LAUNCHER" ]; then
    set +e
    env "${SLUG_UPPER}_DRY_RUN=1" bash "$LAUNCHER" >"$LOG" 2>&1
    RC=$?
    set -e
    if [ $RC -eq 0 ]; then
        ok "dry-run launcher exited 0"
        record 8 "launcher dry-run"    "OK"   "rc=0"
    else
        fail "dry-run launcher exited $RC — see $LOG"
        tail -n 20 "$LOG" | sed 's/^/    | /'
        record 8 "launcher dry-run"    "FAIL" "rc=$RC"
    fi
else
    fail "launcher missing, skipping"
    record 8 "launcher dry-run"    "FAIL" "launcher missing"
fi

# --------------------------------------------------------------------------- #
# Step 9 — tests/sync-vars.py                                                 #
# --------------------------------------------------------------------------- #
header 9 "$TOTAL" "tests/sync-vars.py"
LOG="$LOG_DIR/09-sync-vars.log"
set +e
( cd "$REPO_ROOT" && python3 tests/sync-vars.py ) >"$LOG" 2>&1
RC=$?
set -e
if [ $RC -eq 0 ]; then
    ok "sync-vars passed"
    record 9 "sync-vars"           "OK"   "rc=0"
else
    fail "sync-vars exited $RC — see $LOG"
    tail -n 20 "$LOG" | sed 's/^/    | /'
    record 9 "sync-vars"           "FAIL" "rc=$RC"
fi

# --------------------------------------------------------------------------- #
# Step 10 — cleanup                                                           #
# --------------------------------------------------------------------------- #
header 10 "$TOTAL" "cleanup"
if [ "$KEEP" -eq 1 ]; then
    ok "kept $OUT (--keep)"
    record 10 "cleanup"             "OK"   "kept"
else
    if rm -rf "$OUT" 2>/dev/null; then
        ok "removed $OUT"
        record 10 "cleanup"             "OK"   "removed"
    else
        fail "could not remove $OUT"
        record 10 "cleanup"             "FAIL" "rm failed"
    fi
fi

# --------------------------------------------------------------------------- #
# Summary table                                                               #
# --------------------------------------------------------------------------- #
printf "\n%s%s%s\n" "$C_BOLD" "Summary" "$C_RESET"
printf "%s%-4s %-26s %-6s %s%s\n" "$C_DIM" "#" "Step" "Status" "Detail" "$C_RESET"
printf "%s%s%s\n" "$C_DIM" "---- -------------------------- ------ ------------------------------" "$C_RESET"
for i in 1 2 3 4 5 6 7 8 9 10; do
    name="${STEP_NAMES[$i]:-?}"
    status="${STEP_STATUS[$i]:-SKIP}"
    detail="${STEP_DETAIL[$i]:-}"
    case "$status" in
        OK)   color="$C_GREEN" ;;
        FAIL) color="$C_RED"   ;;
        *)    color="$C_YELLOW" ;;
    esac
    printf "%-4s %-26s %s%-6s%s %s\n" "$i" "$name" "$color" "$status" "$C_RESET" "$detail"
done

printf "\n"
if [ "$FAILURES" -eq 0 ]; then
    printf "%sAll %d steps passed.%s\n" "$C_GREEN" "$TOTAL" "$C_RESET"
else
    if [ "$KEEP" -eq 1 ]; then
        printf "%s%d failure(s) — logs in %s/_logs/%s\n" "$C_RED" "$FAILURES" "$OUT" "$C_RESET"
    else
        printf "%s%d failure(s) — re-run with --keep to inspect %s/_logs/%s\n" "$C_RED" "$FAILURES" "$OUT" "$C_RESET"
    fi
fi

exit "$FAILURES"
