# tpl: shared module — bundled skills installer
# tpl: Sourced by install.sh.tpl. Do NOT `set -euo pipefail` here:
# tpl: the caller already does, and we need to recover from partial failures
# tpl: (e.g. one preset clone fails — we still try the others).
#
# tpl: Variables expected from the rendered launcher:
# tpl:   SKILLS_MODE       one of: none | preset | pick | git | local | combined
# tpl:   SKILLS_PRESETS    JSON-ish array, e.g. ["design-pack","security-pack"]
# tpl:   SKILLS_PICK       JSON-ish array, e.g. ["polish","audit"]
# tpl:   SKILLS_GIT_URL    https URL to an internal skills monorepo
# tpl:   SKILLS_GIT_REF    branch / tag / commit (default: main)
# tpl:   SKILLS_LOCAL_PATH absolute path to a local skills folder
# tpl:   INSTALL_DIR       the launcher install root (already exported by install.sh)
# tpl:   CORP_SLUG         the launcher slug (used for log prefix)

# tpl: ---------- tiny logger (degrades gracefully if not a TTY) ----------
_skills_color() {
    if [ -t 1 ]; then
        case "$1" in
            green)  printf '\033[32m' ;;
            yellow) printf '\033[33m' ;;
            red)    printf '\033[31m' ;;
            dim)    printf '\033[2m'  ;;
            reset)  printf '\033[0m'  ;;
        esac
    fi
}
_skills_info()  { printf '  %s[skills]%s %s\n' "$(_skills_color green)"  "$(_skills_color reset)" "$*"; }
_skills_warn()  { printf '  %s[skills]%s %s\n' "$(_skills_color yellow)" "$(_skills_color reset)" "$*" >&2; }
_skills_fail()  { printf '  %s[skills]%s %s\n' "$(_skills_color red)"    "$(_skills_color reset)" "$*" >&2; }
_skills_step()  { printf '  %s>%s %s\n'        "$(_skills_color dim)"    "$(_skills_color reset)" "$*"; }

# tpl: ---------- preset registry ----------
# tpl: Each preset maps to a git URL + ref. The URL is a publicly maintained
# tpl: skills monorepo curated for this launcher. Add new presets here.
_skills_preset_url() {
    case "$1" in
        design-pack)   printf 'https://github.com/anthropics/skills.git' ;;
        security-pack) printf 'https://github.com/anthropics/security-skills.git' ;;
        data-pack)     printf 'https://github.com/anthropics/data-skills.git' ;;
        ops-pack)      printf 'https://github.com/anthropics/ops-skills.git' ;;
        *)             return 1 ;;
    esac
}
_skills_preset_ref() {
    case "$1" in
        design-pack|security-pack|data-pack|ops-pack) printf 'main' ;;
        *) return 1 ;;
    esac
}

# tpl: ---------- helpers ----------

# tpl: Strip JSON-array syntax to whitespace-separated tokens.
# tpl: Accepts ["a","b"] or "a","b" or a b. Tolerant by design.
_skills_parse_list() {
    local raw="$1"
    printf '%s' "$raw" \
        | tr -d '[]"' \
        | tr ',' ' ' \
        | tr -s ' ' \
        | sed 's/^ *//; s/ *$//'
}

# tpl: Cross-platform recursive copy. Prefer rsync, fall back to cp -R.
_skills_copy_tree() {
    local src="$1" dst="$2"
    mkdir -p "$dst"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete \
            --exclude='.git' --exclude='.DS_Store' --exclude='node_modules' \
            "${src%/}/" "${dst%/}/"
    else
        rm -rf "$dst"
        mkdir -p "$dst"
        # tpl: cp -R copies the directory contents when source ends with /.
        if ! cp -R "${src%/}/." "$dst/" 2>/dev/null; then
            _skills_fail "cp -R failed: $src -> $dst"
            return 1
        fi
    fi
}

# tpl: Shallow clone (or refresh) a git repo at a given ref. Never fatal.
_skills_git_clone_or_pull() {
    local url="$1" ref="$2" dst="$3"
    if ! command -v git >/dev/null 2>&1; then
        _skills_warn "git not installed; skipping $url"
        return 1
    fi
    if [ -d "$dst/.git" ]; then
        _skills_step "refreshing $dst"
        (
            cd "$dst" || exit 1
            git fetch --depth 1 origin "$ref" >/dev/null 2>&1 || true
            git checkout -q "$ref" 2>/dev/null || true
            git pull --ff-only --depth 1 origin "$ref" >/dev/null 2>&1 || true
        ) || _skills_warn "refresh failed for $dst (kept previous version)"
        return 0
    fi
    mkdir -p "$(dirname "$dst")"
    if git clone --depth 1 --branch "$ref" "$url" "$dst" >/dev/null 2>&1; then
        return 0
    fi
    # tpl: branch flag fails for commit SHAs — retry without it.
    if git clone --depth 1 "$url" "$dst" >/dev/null 2>&1; then
        ( cd "$dst" && git checkout -q "$ref" 2>/dev/null ) || true
        return 0
    fi
    _skills_warn "clone failed: $url ($ref) — leaving destination empty"
    rm -rf "$dst"
    return 1
}

# tpl: ---------- mode handlers ----------

_skills_install_preset() {
    local name url ref dst
    for name in $(_skills_parse_list "${SKILLS_PRESETS}"); do
        [ -z "$name" ] && continue
        if ! url=$(_skills_preset_url "$name"); then
            _skills_warn "unknown preset: $name (skipping)"
            continue
        fi
        ref=$(_skills_preset_ref "$name")
        dst="$INSTALL_DIR/skills/$name"
        _skills_step "preset $name <- $url@$ref"
        if _skills_git_clone_or_pull "$url" "$ref" "$dst"; then
            _skills_info "installed preset: $name"
        fi
    done
}

_skills_install_pick() {
    # tpl: "pick" reuses the design-pack registry as the source of single skills.
    # tpl: We clone once into a scratch dir, then copy only the requested subfolders.
    local picks scratch one src dst
    picks=$(_skills_parse_list "${SKILLS_PICK}")
    [ -z "$picks" ] && { _skills_warn "SKILLS_PICK is empty"; return 0; }

    scratch="$INSTALL_DIR/.skills-scratch"
    rm -rf "$scratch"
    if ! _skills_git_clone_or_pull \
            "$(_skills_preset_url design-pack)" \
            "$(_skills_preset_ref design-pack)" \
            "$scratch"; then
        _skills_warn "could not fetch source for pick mode"
        return 1
    fi

    mkdir -p "$INSTALL_DIR/skills/pick"
    for one in $picks; do
        [ -z "$one" ] && continue
        src="$scratch/$one"
        dst="$INSTALL_DIR/skills/pick/$one"
        if [ -d "$src" ]; then
            _skills_copy_tree "$src" "$dst" && _skills_info "picked: $one"
        else
            _skills_warn "skill not found in catalog: $one"
        fi
    done
    rm -rf "$scratch"
}

_skills_install_git() {
    local url="${SKILLS_GIT_URL}" ref="${SKILLS_GIT_REF:-main}"
    local dst="$INSTALL_DIR/skills/internal"
    [ -z "$url" ] && { _skills_warn "SKILLS_GIT_URL is empty"; return 0; }
    _skills_step "internal repo $url@$ref"
    if _skills_git_clone_or_pull "$url" "$ref" "$dst"; then
        _skills_info "internal skills installed at $dst"
    fi
}

_skills_install_local() {
    local src="${SKILLS_LOCAL_PATH}"
    local dst="$INSTALL_DIR/skills/local"
    [ -z "$src" ] && { _skills_warn "SKILLS_LOCAL_PATH is empty"; return 0; }
    # tpl: expand a leading ~ — colleagues may pass ~/work/skills
    case "$src" in
        "~"|"~/"*) src="$HOME/${src#~/}"; src="${src%/}" ;;
    esac
    if [ ! -d "$src" ]; then
        _skills_warn "local skills path not found: $src"
        return 1
    fi
    _skills_step "local $src -> $dst"
    if _skills_copy_tree "$src" "$dst"; then
        _skills_info "local skills copied"
    fi
}

# tpl: ---------- canonical wiring ----------

# tpl: Symlink every skill subfolder under $INSTALL_DIR/skills/**/<skill>
# tpl: into ~/.claude/skills/<skill>. We never overwrite a user-owned skill
# tpl: directory that isn't a symlink (their personal customizations win).
_skills_link_into_claude() {
    local user_skills="$HOME/.claude/skills"
    mkdir -p "$user_skills"

    local skills_root="$INSTALL_DIR/skills"
    [ -d "$skills_root" ] || return 0

    local container skill_dir name target
    local linked=0 kept=0 copied=0

    # tpl: A "skill" is any directory containing a SKILL.md.
    while IFS= read -r skill_dir; do
        [ -z "$skill_dir" ] && continue
        name=$(basename "$skill_dir")
        target="$user_skills/$name"

        if [ -L "$target" ]; then
            # tpl: re-point existing managed symlink
            rm -f "$target"
        elif [ -e "$target" ]; then
            _skills_warn "kept user-owned skill (no overwrite): $target"
            kept=$((kept + 1))
            continue
        fi

        if ln -s "$skill_dir" "$target" 2>/dev/null; then
            linked=$((linked + 1))
        else
            # tpl: Windows/WSL filesystems may refuse symlinks — copy instead.
            if _skills_copy_tree "$skill_dir" "$target"; then
                copied=$((copied + 1))
            else
                _skills_warn "could not wire $name into $user_skills"
            fi
        fi
    done < <(find "$skills_root" -mindepth 2 -maxdepth 4 -name SKILL.md -print 2>/dev/null \
              | while IFS= read -r f; do dirname "$f"; done)

    _skills_info "wired skills into ~/.claude/skills (linked=$linked copied=$copied kept=$kept)"
}

# tpl: ---------- entry point ----------

install_skills() {
    local mode="${SKILLS_MODE:-none}"

    if [ "$mode" = "none" ] || [ -z "$mode" ]; then
        _skills_step "skills bundle: none (skipping)"
        return 0
    fi

    _skills_step "skills bundle: $mode"
    mkdir -p "$INSTALL_DIR/skills"

    case "$mode" in
        preset)   _skills_install_preset ;;
        pick)     _skills_install_pick ;;
        git)      _skills_install_git ;;
        local)    _skills_install_local ;;
        combined)
            # tpl: Each sub-mode is best-effort; one failure must not abort the others.
            [ -n "${SKILLS_PRESETS:-}" ]   && _skills_install_preset || true
            [ -n "${SKILLS_PICK:-}" ]     && _skills_install_pick   || true
            [ -n "${SKILLS_GIT_URL:-}" ]  && _skills_install_git    || true
            [ -n "${SKILLS_LOCAL_PATH:-}" ] && _skills_install_local || true
            ;;
        *)
            _skills_fail "unknown SKILLS_MODE: $mode"
            return 1
            ;;
    esac

    _skills_link_into_claude
    return 0
}

# tpl: ---------- update path ----------
# tpl: Exposed via `<slug> --update-skills`. Re-runs the same flow; git modes
# tpl: get a `git pull`, local mode re-syncs from the source path, presets refresh.
update_skills() {
    _skills_step "refreshing bundled skills"
    install_skills
}
