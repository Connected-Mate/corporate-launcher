#!/usr/bin/env bash
# PreToolUse hook: warn (do not block) if scripts/legal-matrix.json is older
# than reverify_after_days. The actual block lives in generate.py Phase 1.4 —
# this hook is informational, fired just before the user invokes the generator.
set -euo pipefail

SKILL_DIR="${CLAUDE_SKILL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
MATRIX="$SKILL_DIR/scripts/legal-matrix.json"

[ -r "$MATRIX" ] || { exit 0; }

read_date=$(python3 -c "import json,sys; print(json.load(open('$MATRIX')).get('last_read_date',''))" 2>/dev/null || echo "")
reverify=$(python3 -c "import json,sys; print(json.load(open('$MATRIX')).get('reverify_after_days', 180))" 2>/dev/null || echo "180")

[ -z "$read_date" ] && exit 0

age_days=$(python3 -c "
import datetime as d
read=d.date.fromisoformat('$read_date')
today=d.date.today()
print((today-read).days)
" 2>/dev/null || echo 0)

if [ "$age_days" -gt "$reverify" ]; then
    printf '\n  [legal-matrix] WARNING: %s days old (max %s). Re-run the TOS-reading agent before deploying to production.\n\n' "$age_days" "$reverify" >&2
fi

exit 0
