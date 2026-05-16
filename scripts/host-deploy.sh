#!/usr/bin/env bash
# host-deploy.sh — Auto-detect installed AI coding hosts and deploy the
# `corporate-launcher` skill into each of them with a single command.
#
# Supported hosts: Claude Code, Codex CLI, Gemini CLI, Cursor, Cline.
#
# Usage:
#   bash scripts/host-deploy.sh                # auto-detect + interactive prompt
#   bash scripts/host-deploy.sh --all          # install in every detected host
#   bash scripts/host-deploy.sh --host NAME    # explicit single host
#   bash scripts/host-deploy.sh --dry-run      # print actions, change nothing
#   bash scripts/host-deploy.sh --yes          # non-interactive, assume yes
#   bash scripts/host-deploy.sh --help
#
# Portable: macOS + Linux. Bash 3.2+ compatible (default on macOS).

set -eo pipefail

# ---------- ANSI colors ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_MAGENTA=$'\033[35m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""
  C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
fi

SKILL_NAME="corporate-launcher"
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_ROOT="$( cd -- "$SCRIPT_DIR/.." &> /dev/null && pwd )"

DRY_RUN=0
ASSUME_YES=0
INSTALL_ALL=0
EXPLICIT_HOST=""

# ---------- pretty helpers ----------
log()    { printf '%s\n' "$*"; }
info()   { printf '%s[i]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()     { printf '%s[ok]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()   { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()    { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
hr()     { printf '%s%s%s\n' "$C_DIM" "----------------------------------------------------------------" "$C_RESET"; }
title()  { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

usage() {
  cat <<EOF
${C_BOLD}corporate-launcher / host-deploy${C_RESET}

Auto-detects AI coding hosts on this machine and deploys the
'${SKILL_NAME}' skill into each.

Usage:
  bash scripts/host-deploy.sh [options]

Options:
  --all                Install into every detected host
  --host <name>        Install into a single host (claude-code|codex|gemini|cursor|cline)
  --dry-run            Print actions without changing anything
  --yes, -y            Non-interactive; assume yes for prompts
  --help, -h           Show this help

Examples:
  bash scripts/host-deploy.sh
  bash scripts/host-deploy.sh --all
  bash scripts/host-deploy.sh --host claude-code
  bash scripts/host-deploy.sh --dry-run --all
EOF
}

# ---------- arg parsing ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --all)      INSTALL_ALL=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    --host)
      [ $# -ge 2 ] || { err "--host requires a value"; exit 2; }
      EXPLICIT_HOST="$2"; shift 2 ;;
    --host=*)   EXPLICIT_HOST="${1#*=}"; shift ;;
    --help|-h)  usage; exit 0 ;;
    *)          err "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

# ---------- platform paths ----------
detect_cursor_dir() {
  case "$(uname -s)" in
    Darwin) printf '%s' "$HOME/Library/Application Support/Cursor" ;;
    Linux)  printf '%s' "$HOME/.config/Cursor" ;;
    *)      printf '%s' "$HOME/.config/Cursor" ;;
  esac
}

CLAUDE_DIR="$HOME/.claude"
CODEX_DIR="$HOME/.codex"
AGENTS_DIR="$HOME/.agents"
GEMINI_DIR="$HOME/.gemini"
CURSOR_DIR="$(detect_cursor_dir)"
CLINE_RULES_DIR="$HOME/Documents/Cline/Rules"

# ---------- host detection ----------
# Each host: AVAILABLE (yes/no) + REASON (string)

CLAUDE_AVAILABLE=0;  CLAUDE_REASON="not detected"
CODEX_AVAILABLE=0;   CODEX_REASON="not detected"
GEMINI_AVAILABLE=0;  GEMINI_REASON="not detected"
CURSOR_AVAILABLE=0;  CURSOR_REASON="not detected"
CLINE_AVAILABLE=0;   CLINE_REASON="not detected"

detect_hosts() {
  # Claude Code
  if command -v claude >/dev/null 2>&1; then
    CLAUDE_AVAILABLE=1; CLAUDE_REASON="binary: $(command -v claude)"
  elif [ -d "$CLAUDE_DIR" ]; then
    CLAUDE_AVAILABLE=1; CLAUDE_REASON="dir: $CLAUDE_DIR"
  fi

  # Codex CLI
  if command -v codex >/dev/null 2>&1; then
    CODEX_AVAILABLE=1; CODEX_REASON="binary: $(command -v codex)"
  elif [ -d "$CODEX_DIR" ]; then
    CODEX_AVAILABLE=1; CODEX_REASON="dir: $CODEX_DIR"
  elif [ -d "$AGENTS_DIR" ]; then
    CODEX_AVAILABLE=1; CODEX_REASON="dir: $AGENTS_DIR"
  fi

  # Gemini CLI
  if command -v gemini >/dev/null 2>&1; then
    GEMINI_AVAILABLE=1; GEMINI_REASON="binary: $(command -v gemini)"
  elif [ -d "$GEMINI_DIR" ]; then
    GEMINI_AVAILABLE=1; GEMINI_REASON="dir: $GEMINI_DIR"
  fi

  # Cursor
  if command -v cursor >/dev/null 2>&1; then
    CURSOR_AVAILABLE=1; CURSOR_REASON="binary: $(command -v cursor)"
  elif [ -d "$CURSOR_DIR" ]; then
    CURSOR_AVAILABLE=1; CURSOR_REASON="dir: $CURSOR_DIR"
  fi

  # Cline (VS Code extension)
  if command -v code >/dev/null 2>&1; then
    if code --list-extensions 2>/dev/null | grep -qi 'saoudrizwan.claude-dev'; then
      CLINE_AVAILABLE=1; CLINE_REASON="VS Code extension: saoudrizwan.claude-dev"
    fi
  fi
  # Fallback: rules dir already exists
  if [ "$CLINE_AVAILABLE" -eq 0 ] && [ -d "$CLINE_RULES_DIR" ]; then
    CLINE_AVAILABLE=1; CLINE_REASON="dir: $CLINE_RULES_DIR"
  fi
}

print_summary_table() {
  title "Detected hosts"
  hr
  printf '%s%-14s %-9s %s%s\n' "$C_BOLD" "HOST" "STATUS" "DETAIL" "$C_RESET"
  hr
  print_row() {
    local name="$1" avail="$2" reason="$3"
    if [ "$avail" -eq 1 ]; then
      printf '%-14s %s%-9s%s %s\n' "$name" "$C_GREEN" "FOUND" "$C_RESET" "$reason"
    else
      printf '%-14s %s%-9s%s %s\n' "$name" "$C_DIM" "missing" "$C_RESET" "$reason"
    fi
  }
  print_row "claude-code" "$CLAUDE_AVAILABLE" "$CLAUDE_REASON"
  print_row "codex"       "$CODEX_AVAILABLE"  "$CODEX_REASON"
  print_row "gemini"      "$GEMINI_AVAILABLE" "$GEMINI_REASON"
  print_row "cursor"      "$CURSOR_AVAILABLE" "$CURSOR_REASON"
  print_row "cline"       "$CLINE_AVAILABLE"  "$CLINE_REASON"
  hr
}

# ---------- I/O helpers ----------
confirm() {
  # confirm "question?" -> 0 yes / 1 no
  local q="$1"
  if [ "$ASSUME_YES" -eq 1 ]; then return 0; fi
  printf '%s%s%s [y/N] ' "$C_YELLOW" "$q" "$C_RESET"
  local ans=""
  read -r ans || true
  case "$ans" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

run() {
  # run "label" cmd args...
  local label="$1"; shift
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s[dry-run]%s %s -> %s\n' "$C_MAGENTA" "$C_RESET" "$label" "$*"
    return 0
  fi
  "$@"
}

ensure_dir() {
  local d="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s[dry-run]%s mkdir -p "%s"\n' "$C_MAGENTA" "$C_RESET" "$d"
  else
    mkdir -p "$d"
  fi
}

copy_tree() {
  # copy_tree <src> <dest>
  local src="$1" dest="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s[dry-run]%s cp -R "%s" -> "%s"\n' "$C_MAGENTA" "$C_RESET" "$src" "$dest"
    return 0
  fi
  # Use trailing /. to copy contents into dest reliably across platforms
  cp -R "$src/." "$dest/"
}

check_existing() {
  # check_existing <path> <host-label>
  # returns 0 if we should proceed, 1 if user skipped
  local path="$1" label="$2"
  if [ -e "$path" ]; then
    warn "$label already installed at: $path"
    if [ "$ASSUME_YES" -eq 1 ]; then
      info "--yes: overwriting in place"
      return 0
    fi
    if confirm "  Update / overwrite existing $label install?"; then
      return 0
    else
      info "Skipped $label"
      return 1
    fi
  fi
  return 0
}

verify_installed() {
  # verify_installed <skill-md-path> <label>
  local p="$1" label="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would verify: $p"
    return 0
  fi
  if [ -f "$p" ]; then
    ok "$label installed -> $p"
    return 0
  else
    err "$label: expected file missing: $p"
    return 1
  fi
}

# ---------- installers ----------
install_claude_code() {
  title "Installing into Claude Code"
  local dest="$CLAUDE_DIR/skills/$SKILL_NAME"
  check_existing "$dest" "claude-code" || return 0
  ensure_dir "$CLAUDE_DIR/skills"
  ensure_dir "$dest"
  copy_tree "$REPO_ROOT" "$dest"
  verify_installed "$dest/SKILL.md" "claude-code" || return 1
  info "Invoke in Claude Code:  ${C_BOLD}> /${SKILL_NAME}${C_RESET}"
}

install_codex() {
  title "Installing into Codex CLI"
  local dest="$AGENTS_DIR/skills/$SKILL_NAME"
  local src="$REPO_ROOT/integrations/codex"
  if [ ! -d "$src" ]; then
    err "Missing integration source: $src"; return 1
  fi
  check_existing "$dest" "codex" || return 0
  ensure_dir "$AGENTS_DIR/skills"
  ensure_dir "$dest"
  copy_tree "$src" "$dest"
  # AGENTS.md is the canonical marker for codex
  if [ -f "$dest/AGENTS.md" ]; then
    ok "codex installed -> $dest"
  else
    if [ "$DRY_RUN" -eq 0 ]; then
      err "codex: AGENTS.md missing at $dest"; return 1
    fi
  fi
  info "Invoke in Codex CLI:    ${C_BOLD}> /${SKILL_NAME}${C_RESET}"
}

install_gemini() {
  title "Installing into Gemini CLI"
  local dest="$GEMINI_DIR/extensions/$SKILL_NAME"
  local src="$REPO_ROOT/integrations/gemini"
  if [ ! -d "$src" ]; then
    err "Missing integration source: $src"; return 1
  fi
  check_existing "$dest" "gemini" || return 0
  ensure_dir "$GEMINI_DIR/extensions"
  ensure_dir "$dest"
  copy_tree "$src" "$dest"
  if [ -f "$dest/gemini-extension.json" ]; then
    ok "gemini installed -> $dest"
  else
    if [ "$DRY_RUN" -eq 0 ]; then
      err "gemini: gemini-extension.json missing at $dest"; return 1
    fi
  fi
  info "Invoke in Gemini CLI:   ${C_BOLD}> /${SKILL_NAME}${C_RESET}"
}

install_cursor() {
  title "Installing into Cursor"
  warn "Cursor rules are workspace-scoped, not global."
  cat <<EOF

To enable '${SKILL_NAME}' inside a Cursor workspace, copy the rules
folder into your project root:

  ${C_BOLD}cp -R "$REPO_ROOT/integrations/cursor/." <your-project>/.cursor/rules/${C_RESET}

Then reload the Cursor window. The rules will be picked up automatically
for chats that occur in that workspace.

Optionally, you can also drop a global helper at:
  $CURSOR_DIR/User/globalStorage/${SKILL_NAME}/

(skipped here — Cursor does not yet load global rules consistently)
EOF
  info "Invoke in Cursor:       open chat, mention '${SKILL_NAME}'"
}

install_cline() {
  title "Installing into Cline"
  local dest="$CLINE_RULES_DIR/$SKILL_NAME"
  local src="$REPO_ROOT/integrations/cline"
  check_existing "$dest" "cline" || return 0
  ensure_dir "$CLINE_RULES_DIR"
  ensure_dir "$dest"
  if [ -d "$src" ] && [ "$(ls -A "$src" 2>/dev/null)" ]; then
    copy_tree "$src" "$dest"
  else
    # No dedicated cline integration content — fall back to the canonical
    # SKILL.md so Cline still has something to load.
    warn "No content in $src — falling back to copying SKILL.md"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '%s[dry-run]%s cp "%s" "%s"\n' "$C_MAGENTA" "$C_RESET" "$REPO_ROOT/SKILL.md" "$dest/${SKILL_NAME}.md"
    else
      cp "$REPO_ROOT/SKILL.md" "$dest/${SKILL_NAME}.md"
    fi
  fi
  # Workflow file so Cline exposes a callable workflow entry
  local workflow="$dest/workflow.md"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s[dry-run]%s write workflow -> %s\n' "$C_MAGENTA" "$C_RESET" "$workflow"
  else
    cat > "$workflow" <<WF
# Workflow: ${SKILL_NAME}

Invoke the corporate-launcher skill from Cline.

## When to use
- User mentions ${SKILL_NAME}, corporate launch, or related triggers.

## Steps
1. Load the rules in this directory.
2. Follow SKILL.md from the source repo for full procedure.
WF
  fi
  if [ -f "$dest/${SKILL_NAME}.md" ] || [ -f "$dest/SKILL.md" ] || [ "$DRY_RUN" -eq 1 ]; then
    ok "cline installed -> $dest"
  else
    err "cline: install verification failed at $dest"; return 1
  fi
  info "Invoke in Cline:        mention '${SKILL_NAME}' or run the workflow"
}

# ---------- orchestration ----------
declare_targets() {
  # Build TARGETS as a space-separated list of host keys
  TARGETS=""
  add() { TARGETS="$TARGETS $1"; }

  if [ -n "$EXPLICIT_HOST" ]; then
    case "$EXPLICIT_HOST" in
      claude-code|claude) add "claude-code" ;;
      codex)              add "codex" ;;
      gemini)             add "gemini" ;;
      cursor)             add "cursor" ;;
      cline)              add "cline" ;;
      *) err "Unknown host: $EXPLICIT_HOST"; exit 2 ;;
    esac
    return
  fi

  if [ "$INSTALL_ALL" -eq 1 ]; then
    [ "$CLAUDE_AVAILABLE" -eq 1 ] && add "claude-code"
    [ "$CODEX_AVAILABLE"  -eq 1 ] && add "codex"
    [ "$GEMINI_AVAILABLE" -eq 1 ] && add "gemini"
    [ "$CURSOR_AVAILABLE" -eq 1 ] && add "cursor"
    [ "$CLINE_AVAILABLE"  -eq 1 ] && add "cline"
    return
  fi

  # Interactive selection
  title "Select hosts to install into"
  log "  Detected hosts are pre-selected. Reply y/N for each."
  log ""
  prompt_host() {
    local key="$1" avail="$2" label="$3"
    if [ "$avail" -eq 0 ]; then
      log "  ${C_DIM}- ${label}: not detected, skipping${C_RESET}"
      return
    fi
    if confirm "  Install into ${label}?"; then
      add "$key"
    fi
  }
  prompt_host "claude-code" "$CLAUDE_AVAILABLE" "Claude Code"
  prompt_host "codex"       "$CODEX_AVAILABLE"  "Codex CLI"
  prompt_host "gemini"      "$GEMINI_AVAILABLE" "Gemini CLI"
  prompt_host "cursor"      "$CURSOR_AVAILABLE" "Cursor"
  prompt_host "cline"       "$CLINE_AVAILABLE"  "Cline"
}

main() {
  title "corporate-launcher :: host-deploy"
  log "Repo root: $REPO_ROOT"
  [ "$DRY_RUN" -eq 1 ] && warn "DRY-RUN mode: no files will be written."

  detect_hosts
  print_summary_table
  declare_targets

  # Trim leading whitespace
  TARGETS="$(printf '%s' "$TARGETS" | sed 's/^ *//')"

  if [ -z "$TARGETS" ]; then
    warn "No targets selected. Nothing to do."
    exit 0
  fi

  title "Plan"
  for t in $TARGETS; do log "  - $t"; done

  if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
    confirm "Proceed with install?" || { warn "Aborted."; exit 0; }
  fi

  local failed=0
  for t in $TARGETS; do
    case "$t" in
      claude-code) install_claude_code || failed=$((failed+1)) ;;
      codex)       install_codex       || failed=$((failed+1)) ;;
      gemini)      install_gemini      || failed=$((failed+1)) ;;
      cursor)      install_cursor      || failed=$((failed+1)) ;;
      cline)       install_cline       || failed=$((failed+1)) ;;
    esac
  done

  title "Done"
  if [ "$failed" -gt 0 ]; then
    err "$failed host(s) reported errors. See messages above."
    exit 1
  fi
  ok "All selected hosts processed."
  log ""
  log "${C_BOLD}Next step:${C_RESET} open your host and run:"
  log "    ${C_GREEN}> /${SKILL_NAME}${C_RESET}"
}

main "$@"
