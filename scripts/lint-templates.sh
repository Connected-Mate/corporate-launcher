#!/usr/bin/env bash
# lint-templates.sh - Lint .tpl files for corporate-launcher.
#
# Usage:
#   bash scripts/lint-templates.sh [path] [--fix]
#
# Default path: templates/
# Exit codes:
#   0 = no issues
#   1 = errors present
#   2 = warnings only
#
# Checks:
#   E1 lowercase ${var}       (render.py only substitutes UPPERCASE)
#   E2 unescaped runtime vars in .sh.tpl (e.g. ${HOME} should be $\{HOME\})
#   W3 lone $lowercase        (suspicious, may be runtime var typo)
#   W4 missing newline at EOF
#   E5 CRLF line endings
#   W6 tabs in .py.tpl
#   E7 .sh.tpl with shebang but no `set -euo pipefail`
#
# Portable: POSIX bash, no jq, no python.

set -eo pipefail

# ---------------------------------------------------------------- args ----

TARGET="templates"
FIX=0

for arg in "$@"; do
  case "$arg" in
    --fix) FIX=1 ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) TARGET="$arg" ;;
  esac
done

if [ ! -e "$TARGET" ]; then
  printf 'lint-templates: path not found: %s\n' "$TARGET" >&2
  exit 1
fi

# --------------------------------------------------------------- state ----

# Counters (totals)
TOTAL_E1=0; TOTAL_E2=0; TOTAL_W3=0; TOTAL_W4=0
TOTAL_E5=0; TOTAL_W6=0; TOTAL_E7=0
TOTAL_ERR=0; TOTAL_WARN=0; TOTAL_FILES=0; FILES_WITH_ISSUES=0
FIXED_COUNT=0

# Runtime shell vars that must be escaped in .sh.tpl
RUNTIME_VARS='HOME|BASH_SOURCE|SHELL|USER|PATH|PWD|UID|EUID|HOSTNAME|LANG|LC_ALL|TERM|EDITOR|XDG_CONFIG_HOME|XDG_DATA_HOME|XDG_CACHE_HOME|TMPDIR|OSTYPE|MACHTYPE'

# ----------------------------------------------------------- helpers ----

# Print a finding in "file:line: [code] message" form
emit() {
  printf '  %s:%s: [%s] %s\n' "$1" "$2" "$3" "$4"
}

ensure_trailing_newline() {
  # adds a final \n if missing. portable Mac/Linux.
  local f="$1"
  local last
  last=$(tail -c 1 "$f" 2>/dev/null || true)
  if [ -n "$last" ]; then
    printf '\n' >> "$f"
    return 0
  fi
  return 1
}

strip_crlf() {
  # Remove \r before \n.
  local f="$1"
  local tmp
  tmp=$(mktemp)
  # tr is portable
  tr -d '\r' < "$f" > "$tmp"
  mv "$tmp" "$f"
}

# ------------------------------------------------------------- scan ----

# Collect .tpl files
TPL_LIST=$(mktemp)
if [ -d "$TARGET" ]; then
  find "$TARGET" -type f -name '*.tpl' | LC_ALL=C sort > "$TPL_LIST"
else
  printf '%s\n' "$TARGET" > "$TPL_LIST"
fi

# Summary table accumulator (file<TAB>err<TAB>warn)
SUMMARY=$(mktemp)

while IFS= read -r f; do
  [ -z "$f" ] && continue
  TOTAL_FILES=$((TOTAL_FILES + 1))

  file_err=0
  file_warn=0
  file_e1=0; file_e2=0; file_w3=0; file_w4=0; file_e5=0; file_w6=0; file_e7=0

  printf '== %s\n' "$f"

  # E5: CRLF detection (do first; if --fix, normalize before further checks)
  if LC_ALL=C grep -q $'\r' "$f" 2>/dev/null; then
    file_e5=1
    emit "$f" "-" "E5" "CRLF line endings detected"
    if [ "$FIX" -eq 1 ]; then
      strip_crlf "$f"
      printf '    fixed: stripped CRLF\n'
      FIXED_COUNT=$((FIXED_COUNT + 1))
      file_e5=0
    fi
  fi

  # E1: lowercase ${var}
  # Skip comments starting with '# tpl:' to avoid false positives on examples
  while IFS=: read -r lineno match; do
    [ -z "$lineno" ] && continue
    # ignore lines that are stripped tpl comments noting examples
    case "$match" in
      *'# tpl:'*) continue ;;
    esac
    file_e1=$((file_e1 + 1))
    emit "$f" "$lineno" "E1" "lowercase render var: $(printf '%s' "$match" | grep -oE '\$\{[a-z][a-zA-Z0-9_]*\}' | head -1)"
  done < <(grep -nE '\$\{[a-z][a-zA-Z0-9_]*\}' "$f" 2>/dev/null || true)

  # E2/E7: .sh.tpl-specific checks
  case "$f" in
    *.sh.tpl)
      # E2: unescaped runtime shell vars like ${HOME} (should be $\{HOME\})
      # Detect literal ${VAR} where VAR is a known runtime var, and the '{' is not preceded by '\'
      while IFS=: read -r lineno match; do
        [ -z "$lineno" ] && continue
        # skip tpl comments
        case "$match" in
          *'# tpl:'*) continue ;;
        esac
        # Render-time vars are intentional. We only flag runtime ones.
        var=$(printf '%s' "$match" | grep -oE '\$\{('"$RUNTIME_VARS"')\}' | head -1)
        [ -z "$var" ] && continue
        # Check that this occurrence is NOT escaped as $\{VAR\}
        # If line contains the escaped form for the same var, skip.
        vname=$(printf '%s' "$var" | sed -E 's/^\$\{//;s/\}$//')
        if printf '%s' "$match" | grep -qE '\$\\\{'"$vname"'\\\}'; then
          # both escaped and unescaped on same line: still flag unescaped
          :
        fi
        file_e2=$((file_e2 + 1))
        emit "$f" "$lineno" "E2" "unescaped runtime var $var (use \$\\{$vname\\} in template)"
      done < <(grep -nE '\$\{('"$RUNTIME_VARS"')\}' "$f" 2>/dev/null || true)

      # E7: shebang present but missing `set -euo pipefail`
      first_line=$(head -n 1 "$f" 2>/dev/null || true)
      case "$first_line" in
        '#!'*)
          if ! grep -qE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e[a-zA-Z]*[ou]?[a-zA-Z]*[[:space:]]+pipefail' "$f" \
             && ! grep -qE '^[[:space:]]*set[[:space:]]+-euo[[:space:]]+pipefail' "$f"; then
            file_e7=1
            emit "$f" "1" "E7" "shebang present but missing 'set -euo pipefail'"
          fi
          ;;
      esac
      ;;
  esac

  # W3: lone $lowercase (e.g. $home) - not preceded by \ and not part of ${...}
  # Skip PowerShell templates: $var is the native syntax there.
  case "$f" in
    *.ps1.tpl) skip_w3=1 ;;
    *) skip_w3=0 ;;
  esac
  if [ "$skip_w3" -eq 1 ]; then
    : # noop
  else
  while IFS=: read -r lineno match; do
    [ -z "$lineno" ] && continue
    case "$match" in
      *'# tpl:'*) continue ;;
    esac
    file_w3=$((file_w3 + 1))
    tok=$(printf '%s' "$match" | grep -oE '(^|[^\\$])\$[a-z][a-zA-Z0-9_]*' | head -1 | sed -E 's/^[^$]*//')
    emit "$f" "$lineno" "W3" "lone lowercase shell var: $tok"
  done < <(grep -nE '(^|[^\\$])\$[a-z][a-zA-Z0-9_]*' "$f" 2>/dev/null || true)
  fi

  # W6: tabs in .py.tpl
  case "$f" in
    *.py.tpl)
      while IFS=: read -r lineno _; do
        [ -z "$lineno" ] && continue
        file_w6=$((file_w6 + 1))
        emit "$f" "$lineno" "W6" "tab character (PEP8: use spaces)"
      done < <(grep -nP '\t' "$f" 2>/dev/null || grep -n $'\t' "$f" 2>/dev/null || true)
      ;;
  esac

  # W4: missing trailing newline
  if [ -s "$f" ]; then
    last_byte=$(tail -c 1 "$f" 2>/dev/null || true)
    if [ -n "$last_byte" ]; then
      file_w4=1
      emit "$f" "EOF" "W4" "missing newline at end of file"
      if [ "$FIX" -eq 1 ]; then
        ensure_trailing_newline "$f" || true
        printf '    fixed: appended trailing newline\n'
        FIXED_COUNT=$((FIXED_COUNT + 1))
        file_w4=0
      fi
    fi
  fi

  # Tally per-file: E* = errors, W* = warnings
  file_err=$((file_e1 + file_e2 + file_e5 + file_e7))
  file_warn=$((file_w3 + file_w4 + file_w6))

  TOTAL_E1=$((TOTAL_E1 + file_e1))
  TOTAL_E2=$((TOTAL_E2 + file_e2))
  TOTAL_W3=$((TOTAL_W3 + file_w3))
  TOTAL_W4=$((TOTAL_W4 + file_w4))
  TOTAL_E5=$((TOTAL_E5 + file_e5))
  TOTAL_W6=$((TOTAL_W6 + file_w6))
  TOTAL_E7=$((TOTAL_E7 + file_e7))
  TOTAL_ERR=$((TOTAL_ERR + file_err))
  TOTAL_WARN=$((TOTAL_WARN + file_warn))

  if [ $((file_err + file_warn)) -gt 0 ]; then
    FILES_WITH_ISSUES=$((FILES_WITH_ISSUES + 1))
    printf '   -> %d error(s), %d warning(s)\n' "$file_err" "$file_warn"
    printf '%s\t%d\t%d\n' "$f" "$file_err" "$file_warn" >> "$SUMMARY"
  else
    printf '   -> clean\n'
  fi

done < "$TPL_LIST"

rm -f "$TPL_LIST"

# ---------------------------------------------------------- summary ----

printf '\n'
printf '====================== SUMMARY ======================\n'
printf 'Files scanned        : %d\n' "$TOTAL_FILES"
printf 'Files with issues    : %d\n' "$FILES_WITH_ISSUES"
printf '\n'
printf '%s\n' 'Code  Severity  Count  Description'
printf '%s\n' '----  --------  -----  -----------'
printf 'E1    error     %5d  lowercase ${var}\n'              "$TOTAL_E1"
printf 'E2    error     %5d  unescaped runtime var in .sh.tpl\n' "$TOTAL_E2"
printf 'E5    error     %5d  CRLF line endings\n'             "$TOTAL_E5"
printf 'E7    error     %5d  .sh.tpl missing set -euo pipefail\n' "$TOTAL_E7"
printf 'W3    warning   %5d  lone $lowercase\n'               "$TOTAL_W3"
printf 'W4    warning   %5d  missing newline at EOF\n'        "$TOTAL_W4"
printf 'W6    warning   %5d  tab in .py.tpl\n'                "$TOTAL_W6"
printf '%s\n' '----  --------  -----'
printf 'TOTAL errors      : %d\n' "$TOTAL_ERR"
printf 'TOTAL warnings    : %d\n' "$TOTAL_WARN"
if [ "$FIX" -eq 1 ]; then
  printf 'Auto-fixed items  : %d\n' "$FIXED_COUNT"
fi

if [ -s "$SUMMARY" ]; then
  printf '\nPer-file breakdown:\n'
  printf '%-70s  %6s  %6s\n' "FILE" "ERR" "WARN"
  printf '%-70s  %6s  %6s\n' "----" "---" "----"
  while IFS=$'\t' read -r ff fe fw; do
    printf '%-70s  %6s  %6s\n' "$ff" "$fe" "$fw"
  done < "$SUMMARY"
fi
rm -f "$SUMMARY"

printf '=====================================================\n'

# Exit code policy
if [ "$TOTAL_ERR" -gt 0 ]; then
  exit 1
elif [ "$TOTAL_WARN" -gt 0 ]; then
  exit 2
fi
exit 0
