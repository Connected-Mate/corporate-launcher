# tpl: ---------------------------------------------------------------------
# tpl: shared module — launcher self-update
# tpl: Sourced by templates/<cli>/launcher.sh.tpl when the user runs
# tpl:   ${CORP_SLUG} --update            (apply)
# tpl:   ${CORP_SLUG} --check-updates     (probe only)
# tpl:
# tpl: Do NOT `set -euo pipefail` here — the caller already did, and we want
# tpl: to recover from partial failures (e.g. underlying CLI upgraded but
# tpl: skills repo unreachable: keep the win, warn on the loss).
# tpl:
# tpl: Variables expected from the rendered launcher.sh:
# tpl:   INSTALL_DIR          launcher install root (= ${CORP_SLUG_UPPER}_HOME)
# tpl:   CORP_NAME            display name
# tpl:   CORP_SLUG            kebab-case slug
# tpl:   CORP_LAUNCHER_VERSION  semver pinned at render-time
# tpl:   CC_PIN_VERSION       optional npm pin (Claude Code only)
# tpl:   DIST_MODE            public-git | private-git | tarball | oneliner | none
# tpl:   DIST_REPO_URL        if git-based
# tpl:   DIST_ONELINER_HOST   if oneliner
# tpl:   DIST_REGISTRY_URL    if tarball
# tpl:   PROVIDER_KIND        claude-code | codex-cli | gemini-cli | aider | opencode
# tpl: ---------------------------------------------------------------------

# tpl: ---------- tiny logger (TTY-aware) ----------
_upd_color() {
    if [ -t 1 ]; then
        case "$1" in
            green)  printf '\033[32m' ;;
            yellow) printf '\033[33m' ;;
            red)    printf '\033[31m' ;;
            bold)   printf '\033[1m'  ;;
            dim)    printf '\033[2m'  ;;
            reset)  printf '\033[0m'  ;;
        esac
    fi
}
_upd_info() { printf '  %s[update]%s %s\n' "$(_upd_color green)"  "$(_upd_color reset)" "$*"; }
_upd_warn() { printf '  %s[update]%s %s\n' "$(_upd_color yellow)" "$(_upd_color reset)" "$*" >&2; }
_upd_fail() { printf '  %s[update]%s %s\n' "$(_upd_color red)"    "$(_upd_color reset)" "$*" >&2; }
_upd_step() { printf '\n  %s>%s %s\n'      "$(_upd_color bold)"   "$(_upd_color reset)" "$*"; }
_upd_dim()  { printf '    %s%s%s\n'        "$(_upd_color dim)"    "$*" "$(_upd_color reset)"; }

# tpl: ---------------------------------------------------------------------
# tpl: detect_install_kind — read manifest or scan
# tpl: Sets globals:
# tpl:   UPD_PROVIDER     claude-code|codex-cli|gemini-cli|aider|opencode
# tpl:   UPD_DIST_MODE    public-git|private-git|tarball|oneliner|none
# tpl:   UPD_CUR_VERSION  current launcher semver
# tpl: ---------------------------------------------------------------------
_upd_detect_install_kind() {
    local manifest="$\{INSTALL_DIR\}/.manifest"
    UPD_PROVIDER="${PROVIDER_KIND}"
    UPD_DIST_MODE="${DIST_MODE}"
    UPD_CUR_VERSION="${CORP_LAUNCHER_VERSION}"

    if [ -r "$manifest" ]; then
        # tpl: manifest is plain `key=value` — never source it (no code exec)
        local k v
        while IFS='=' read -r k v; do
            case "$k" in
                provider)       UPD_PROVIDER="$v" ;;
                dist_mode)      UPD_DIST_MODE="$v" ;;
                launcher_version) UPD_CUR_VERSION="$v" ;;
            esac
        done < "$manifest"
        _upd_dim "manifest: provider=$UPD_PROVIDER dist=$UPD_DIST_MODE v=$UPD_CUR_VERSION"
        return 0
    fi

    # tpl: fall-back — scan the install dir for hints
    if [ -d "$\{INSTALL_DIR\}/.git" ]; then
        UPD_DIST_MODE="private-git"
    elif [ -f "$\{INSTALL_DIR\}/.tarball-source" ]; then
        UPD_DIST_MODE="tarball"
    elif [ -f "$\{INSTALL_DIR\}/.oneliner-source" ]; then
        UPD_DIST_MODE="oneliner"
    fi
    _upd_dim "scanned: provider=$UPD_PROVIDER dist=$UPD_DIST_MODE v=$UPD_CUR_VERSION"
}

# tpl: ---------------------------------------------------------------------
# tpl: _upd_current_cli_version — best-effort `--version` probe
# tpl: ---------------------------------------------------------------------
_upd_current_cli_version() {
    case "$UPD_PROVIDER" in
        claude-code)  command -v claude     >/dev/null 2>&1 && claude     --version 2>/dev/null | head -n1 ;;
        codex-cli)    command -v codex      >/dev/null 2>&1 && codex      --version 2>/dev/null | head -n1 ;;
        gemini-cli)   command -v gemini     >/dev/null 2>&1 && gemini     --version 2>/dev/null | head -n1 ;;
        aider)        command -v aider      >/dev/null 2>&1 && aider      --version 2>/dev/null | head -n1 ;;
        opencode)     command -v opencode   >/dev/null 2>&1 && opencode   --version 2>/dev/null | head -n1 ;;
        *)            return 1 ;;
    esac
}

# tpl: ---------------------------------------------------------------------
# tpl: _upd_latest_cli_version — query the upstream registry (best-effort)
# tpl: Returns 0 + prints version on success, 1 on failure.
# tpl: ---------------------------------------------------------------------
_upd_latest_cli_version() {
    case "$UPD_PROVIDER" in
        claude-code)  command -v npm >/dev/null 2>&1 && npm view @anthropic-ai/claude-code version 2>/dev/null ;;
        codex-cli)    command -v npm >/dev/null 2>&1 && npm view @openai/codex            version 2>/dev/null ;;
        gemini-cli)   command -v npm >/dev/null 2>&1 && npm view @google/gemini-cli       version 2>/dev/null ;;
        opencode)     command -v npm >/dev/null 2>&1 && npm view opencode-ai              version 2>/dev/null ;;
        aider)
            if command -v pip >/dev/null 2>&1; then
                pip index versions aider-install 2>/dev/null | awk -F'[(),]' '/Available/{print $2; exit}' | tr -d ' '
            fi
            ;;
        *) return 1 ;;
    esac
}

# tpl: ---------------------------------------------------------------------
# tpl: _upd_backup — snapshot the install dir before mutating it
# tpl: Returns the backup path on stdout.
# tpl: ---------------------------------------------------------------------
_upd_backup() {
    local stamp
    stamp=$(date +%Y%m%d-%H%M%S)
    local backup="$\{INSTALL_DIR\}.bak.$\{stamp\}"
    # tpl: hard-link cp -al on Linux is instant; macOS falls back to cp -a
    if cp -al "$INSTALL_DIR" "$backup" 2>/dev/null; then
        :
    else
        cp -a  "$INSTALL_DIR" "$backup"
    fi
    printf '%s' "$backup"
}

_upd_rollback() {
    local backup="$1"
    [ -d "$backup" ] || { _upd_fail "rollback impossible: backup $backup missing"; return 1; }
    _upd_warn "rolling back from $backup"
    rm -rf "$\{INSTALL_DIR\}.broken" 2>/dev/null || true
    mv "$INSTALL_DIR" "$\{INSTALL_DIR\}.broken"
    mv "$backup"      "$INSTALL_DIR"
    _upd_info "rolled back; broken tree preserved at $\{INSTALL_DIR\}.broken"
}

# tpl: ---------------------------------------------------------------------
# tpl: _upd_underlying_cli — update the wrapped CLI binary
# tpl: Respects CC_PIN_VERSION if set (Claude Code only).
# tpl: ---------------------------------------------------------------------
_upd_underlying_cli() {
    _upd_step "[1/6] Update underlying CLI ($UPD_PROVIDER)"
    case "$UPD_PROVIDER" in
        claude-code)
            command -v npm >/dev/null 2>&1 || { _upd_fail "npm missing"; return 1; }
            if [ -n "$\{CC_PIN_VERSION:-\}" ] && [ "${CC_PIN_VERSION}" != "" ]; then
                _upd_info "pinned to ${CC_PIN_VERSION}, reinstalling"
                npm install -g "@anthropic-ai/claude-code@${CC_PIN_VERSION}"
            else
                npm update -g @anthropic-ai/claude-code
            fi
            ;;
        codex-cli)
            command -v npm >/dev/null 2>&1 || { _upd_fail "npm missing"; return 1; }
            npm update -g @openai/codex
            ;;
        gemini-cli)
            command -v npm >/dev/null 2>&1 || { _upd_fail "npm missing"; return 1; }
            npm update -g @google/gemini-cli
            ;;
        opencode)
            command -v npm >/dev/null 2>&1 || { _upd_fail "npm missing"; return 1; }
            npm update -g opencode-ai
            ;;
        aider)
            if command -v pipx >/dev/null 2>&1; then
                pipx upgrade aider-install || pipx install --force aider-install
                command -v aider-install >/dev/null 2>&1 && aider-install || true
            elif command -v pip >/dev/null 2>&1; then
                pip install --user --upgrade aider-install
            else
                _upd_fail "neither pipx nor pip found — cannot upgrade aider"
                return 1
            fi
            ;;
        *)
            _upd_warn "unknown provider '$UPD_PROVIDER' — skipping CLI upgrade"
            return 0
            ;;
    esac
    _upd_info "CLI upgraded"
}

# tpl: ---------------------------------------------------------------------
# tpl: _upd_launcher_tree — refresh the launcher files themselves
# tpl: Strategy depends on DIST_MODE.
# tpl: ---------------------------------------------------------------------
_upd_launcher_tree() {
    _upd_step "[2/6] Update launcher tree ($UPD_DIST_MODE)"
    case "$UPD_DIST_MODE" in
        public-git|private-git)
            if [ ! -d "$\{INSTALL_DIR\}/.git" ]; then
                _upd_warn "no .git in $INSTALL_DIR — cannot pull"
                return 1
            fi
            git -C "$INSTALL_DIR" pull --rebase --autostash || {
                _upd_fail "git pull failed"
                return 1
            }
            ;;
        tarball)
            local registry="${DIST_REGISTRY_URL}"
            [ -n "$registry" ] || { _upd_fail "DIST_REGISTRY_URL empty"; return 1; }
            local tmpdir
            tmpdir=$(mktemp -d -t "${CORP_SLUG}-upd.XXXXXX")
            (
                cd "$tmpdir" || exit 1
                curl -fsSL -o "${CORP_SLUG}-latest.tar.gz" "$\{registry%/\}/${CORP_SLUG}-latest.tar.gz" || exit 1
                curl -fsSL -o "SHA256SUMS"                 "$\{registry%/\}/SHA256SUMS"                 || exit 1
                if command -v sha256sum >/dev/null 2>&1; then
                    sha256sum  -c SHA256SUMS --ignore-missing || exit 1
                else
                    shasum -a 256 -c SHA256SUMS              || exit 1
                fi
                mkdir extracted
                tar -xzf "${CORP_SLUG}-latest.tar.gz" -C extracted --strip-components=1
            ) || { _upd_fail "tarball download/verify failed"; rm -rf "$tmpdir"; return 1; }
            # tpl: atomic swap — keep the backup, rsync new files in
            if command -v rsync >/dev/null 2>&1; then
                rsync -a --delete --exclude=.manifest --exclude=secrets \
                      "$tmpdir/extracted/" "$INSTALL_DIR/" || { _upd_fail "rsync failed"; rm -rf "$tmpdir"; return 1; }
            else
                cp -a "$tmpdir/extracted/." "$INSTALL_DIR/"
            fi
            rm -rf "$tmpdir"
            ;;
        oneliner)
            local host="${DIST_ONELINER_HOST}"
            [ -n "$host" ] || { _upd_fail "DIST_ONELINER_HOST empty"; return 1; }
            local tmp_install
            tmp_install=$(mktemp -t "${CORP_SLUG}-install.XXXXXX.sh")
            curl -fsSL -o "$tmp_install" "$\{host%/\}/install.sh" || {
                _upd_fail "fetch $host/install.sh failed"
                rm -f "$tmp_install"
                return 1
            }
            # tpl: verify checksum if companion file is published
            local tmp_sum
            tmp_sum=$(mktemp -t "${CORP_SLUG}-install.XXXXXX.sha256")
            if curl -fsSL -o "$tmp_sum" "$\{host%/\}/install.sh.sha256" 2>/dev/null; then
                ( cd "$(dirname "$tmp_install")" && \
                  ( command -v sha256sum >/dev/null 2>&1 \
                      && sha256sum  -c "$tmp_sum" \
                      || shasum -a 256 -c "$tmp_sum" ) ) \
                  || { _upd_fail "checksum mismatch on install.sh"; rm -f "$tmp_install" "$tmp_sum"; return 1; }
                _upd_info "install.sh checksum verified"
            else
                _upd_warn "no install.sh.sha256 published — proceeding without checksum"
            fi
            rm -f "$tmp_sum"
            chmod +x "$tmp_install"
            ${CORP_SLUG_UPPER}_REINSTALL=1 bash "$tmp_install" --update-mode || {
                _upd_fail "re-run of install.sh failed"
                rm -f "$tmp_install"
                return 1
            }
            rm -f "$tmp_install"
            ;;
        none|"")
            _upd_warn "DIST_MODE=none — launcher tree stays as-is (local-only install)"
            ;;
        *)
            _upd_warn "unknown DIST_MODE '$UPD_DIST_MODE' — skipping tree update"
            ;;
    esac
    _upd_info "launcher tree refreshed"
}

# tpl: ---------------------------------------------------------------------
# tpl: _upd_skills — refresh bundled skills via the installer script
# tpl: ---------------------------------------------------------------------
_upd_skills() {
    _upd_step "[3/6] Update bundled skills"
    local script="$\{INSTALL_DIR\}/scripts/skills-installer.py"
    if [ ! -x "$script" ] && [ ! -r "$script" ]; then
        _upd_dim "no skills-installer.py — skipping"
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        _upd_warn "python3 missing — cannot refresh skills"
        return 0
    fi
    python3 "$script" --update || _upd_warn "skills-installer reported errors (non-fatal)"
}

# tpl: ---------------------------------------------------------------------
# tpl: _upd_settings — re-render settings.json from the (possibly new) template
# tpl: ---------------------------------------------------------------------
_upd_settings() {
    _upd_step "[4/6] Refresh settings.json"
    case "$UPD_PROVIDER" in
        claude-code)
            local src="$\{INSTALL_DIR\}/settings.json"
            local dst="$\{HOME\}/.claude/settings.json"
            if [ -r "$src" ]; then
                mkdir -p "$(dirname "$dst")"
                # tpl: never clobber a user-edited file silently
                if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
                    cp "$dst" "$\{dst\}.${CORP_SLUG}.bak"
                    _upd_dim "backup: $\{dst\}.${CORP_SLUG}.bak"
                fi
                install -m 0600 "$src" "$dst"
                _upd_info "wrote $dst"
            fi
            ;;
        aider)
            local src="$\{INSTALL_DIR\}/aider.conf.yml"
            local dst="$\{HOME\}/.aider.conf.yml"
            if [ -r "$src" ]; then
                if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
                    cp "$dst" "$\{dst\}.${CORP_SLUG}.bak"
                    _upd_dim "backup: $\{dst\}.${CORP_SLUG}.bak"
                fi
                install -m 0644 "$src" "$dst"
                _upd_info "wrote $dst"
            fi
            ;;
        codex-cli)
            local src="$\{INSTALL_DIR\}/config.toml"
            local dst="$\{HOME\}/.codex/config.toml"
            if [ -r "$src" ]; then
                mkdir -p "$(dirname "$dst")"
                [ -f "$dst" ] && ! cmp -s "$src" "$dst" && cp "$dst" "$\{dst\}.${CORP_SLUG}.bak"
                install -m 0600 "$src" "$dst"
                _upd_info "wrote $dst"
            fi
            ;;
        gemini-cli)
            local src="$\{INSTALL_DIR\}/gemini-settings.json"
            local dst="$\{HOME\}/.gemini/settings.json"
            if [ -r "$src" ]; then
                mkdir -p "$(dirname "$dst")"
                [ -f "$dst" ] && ! cmp -s "$src" "$dst" && cp "$dst" "$\{dst\}.${CORP_SLUG}.bak"
                install -m 0600 "$src" "$dst"
                _upd_info "wrote $dst"
            fi
            ;;
        opencode)
            local src="$\{INSTALL_DIR\}/opencode.json"
            local dst="$\{HOME\}/.config/opencode/opencode.json"
            if [ -r "$src" ]; then
                mkdir -p "$(dirname "$dst")"
                [ -f "$dst" ] && ! cmp -s "$src" "$dst" && cp "$dst" "$\{dst\}.${CORP_SLUG}.bak"
                install -m 0600 "$src" "$dst"
                _upd_info "wrote $dst"
            fi
            ;;
        *)
            _upd_dim "no settings step for provider '$UPD_PROVIDER'"
            ;;
    esac
}

# tpl: ---------------------------------------------------------------------
# tpl: _upd_smoke_test — dry-run launch + --version
# tpl: ---------------------------------------------------------------------
_upd_smoke_test() {
    _upd_step "[5/6] Smoke test"
    local launcher="$\{INSTALL_DIR\}/${CORP_SLUG}"
    if [ ! -x "$launcher" ]; then
        _upd_fail "launcher not executable: $launcher"
        return 1
    fi
    if ! "$launcher" --version >/dev/null 2>&1; then
        _upd_fail "$launcher --version failed"
        return 1
    fi
    _upd_info "--version: $("$launcher" --version 2>/dev/null | head -n1)"
    # tpl: dry-run probes env wiring without exec'ing the underlying CLI
    if ${CORP_SLUG_UPPER}_DRY_RUN=1 "$launcher" >/dev/null 2>&1; then
        _upd_info "dry-run OK"
    else
        _upd_warn "dry-run returned non-zero (may be fine if no dry-run support)"
    fi
}

# tpl: ---------------------------------------------------------------------
# tpl: do_update — orchestrator
# tpl: ---------------------------------------------------------------------
do_update() {
    local start_ts end_ts
    start_ts=$(date +%s)

    _upd_step "${CORP_NAME} — self-update"
    _upd_detect_install_kind

    _upd_step "[0/6] Snapshot install tree"
    local backup
    backup=$(_upd_backup)
    _upd_info "backup at $backup"

    local cli_ok=0 tree_ok=0 skills_ok=0 settings_ok=0 smoke_ok=0
    local cli_before cli_after
    cli_before=$(_upd_current_cli_version || printf 'unknown')

    if _upd_underlying_cli; then cli_ok=1; fi
    if _upd_launcher_tree;  then tree_ok=1; fi
    if _upd_skills;         then skills_ok=1; fi
    if _upd_settings;       then settings_ok=1; fi
    if _upd_smoke_test;     then smoke_ok=1; fi

    cli_after=$(_upd_current_cli_version || printf 'unknown')

    _upd_step "[6/6] Summary"
    end_ts=$(date +%s)
    local dur=$(( end_ts - start_ts ))
    _upd_info "provider     : $UPD_PROVIDER"
    _upd_info "dist mode    : $UPD_DIST_MODE"
    _upd_info "CLI before   : $cli_before"
    _upd_info "CLI after    : $cli_after"
    _upd_info "underlying   : $([ $cli_ok      = 1 ] && echo updated || echo SKIPPED)"
    _upd_info "tree         : $([ $tree_ok     = 1 ] && echo updated || echo SKIPPED)"
    _upd_info "skills       : $([ $skills_ok   = 1 ] && echo updated || echo SKIPPED)"
    _upd_info "settings     : $([ $settings_ok = 1 ] && echo refreshed || echo SKIPPED)"
    _upd_info "smoke test   : $([ $smoke_ok    = 1 ] && echo passed  || echo FAILED)"
    _upd_info "duration     : $\{dur\}s"

    if [ "$smoke_ok" != 1 ]; then
        _upd_fail "smoke test failed — rolling back"
        _upd_rollback "$backup"
        return 1
    fi

    # tpl: keep the last 3 backups, prune older
    ( cd "$(dirname "$INSTALL_DIR")" 2>/dev/null && \
      ls -1dt "$(basename "$INSTALL_DIR")".bak.* 2>/dev/null | \
        tail -n +4 | xargs -I {} rm -rf {} ) || true

    _upd_info "update complete"
    return 0
}

# tpl: ---------------------------------------------------------------------
# tpl: check_for_updates — non-mutating probe
# tpl: Prints "vX.Y.Z available (currently vA.B.C)" for each component.
# tpl: Never prompts. Safe to wire into cron / shell-rc nag.
# tpl: ---------------------------------------------------------------------
check_for_updates() {
    _upd_detect_install_kind

    _upd_step "${CORP_NAME} — check for updates"

    # tpl: ----- underlying CLI -----
    local cli_cur cli_new
    cli_cur=$(_upd_current_cli_version 2>/dev/null || printf '')
    cli_new=$(_upd_latest_cli_version 2>/dev/null || printf '')
    if [ -n "$cli_new" ] && [ -n "$cli_cur" ] && [ "$cli_new" != "$cli_cur" ]; then
        printf '  %sCLI%s          v%s available (currently %s)\n' \
            "$(_upd_color bold)" "$(_upd_color reset)" "$cli_new" "$cli_cur"
    elif [ -n "$cli_new" ]; then
        printf '  CLI          up to date (v%s)\n' "$cli_new"
    else
        printf '  CLI          version probe unavailable\n'
    fi

    # tpl: ----- launcher tree -----
    case "$UPD_DIST_MODE" in
        public-git|private-git)
            if [ -d "$\{INSTALL_DIR\}/.git" ]; then
                ( cd "$INSTALL_DIR" && git fetch --quiet 2>/dev/null ) || true
                local ahead behind
                ahead=$(  git -C "$INSTALL_DIR" rev-list --count HEAD..@'{u}' 2>/dev/null || printf '0')
                behind=$( git -C "$INSTALL_DIR" rev-list --count @'{u}'..HEAD 2>/dev/null || printf '0')
                if [ "$ahead" != "0" ]; then
                    printf '  launcher     %s commit(s) behind upstream (run --update)\n' "$ahead"
                else
                    printf '  launcher     up to date (v%s)\n' "$UPD_CUR_VERSION"
                fi
            fi
            ;;
        tarball)
            if [ -n "${DIST_REGISTRY_URL}" ] && command -v curl >/dev/null 2>&1; then
                local remote_ver
                remote_ver=$(curl -fsSL "$\{DIST_REGISTRY_URL%/\}/VERSION" 2>/dev/null | head -n1 | tr -d '[:space:]')
                if [ -n "$remote_ver" ] && [ "$remote_ver" != "$UPD_CUR_VERSION" ]; then
                    printf '  launcher     v%s available (currently v%s)\n' "$remote_ver" "$UPD_CUR_VERSION"
                else
                    printf '  launcher     up to date (v%s)\n' "$UPD_CUR_VERSION"
                fi
            fi
            ;;
        oneliner)
            if [ -n "${DIST_ONELINER_HOST}" ] && command -v curl >/dev/null 2>&1; then
                local remote_ver
                remote_ver=$(curl -fsSL "$\{DIST_ONELINER_HOST%/\}/VERSION" 2>/dev/null | head -n1 | tr -d '[:space:]')
                if [ -n "$remote_ver" ] && [ "$remote_ver" != "$UPD_CUR_VERSION" ]; then
                    printf '  launcher     v%s available (currently v%s)\n' "$remote_ver" "$UPD_CUR_VERSION"
                else
                    printf '  launcher     up to date (v%s)\n' "$UPD_CUR_VERSION"
                fi
            fi
            ;;
        *)
            printf '  launcher     local-only (v%s) — no upstream to probe\n' "$UPD_CUR_VERSION"
            ;;
    esac
    return 0
}
