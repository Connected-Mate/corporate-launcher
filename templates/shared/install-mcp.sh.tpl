# tpl: shared module — MCP servers wiring
# tpl: Sourced by per-CLI install.sh scripts. Reads ${MCP_SERVERS} (a JSON
# tpl: array string) and writes the corresponding native config block into
# tpl: each wrapped CLI's home directory (~/.claude, ~/.codex, ~/.gemini).
# tpl:
# tpl: Servers are also appended to the cyber-hardened MCP allowlist so a
# tpl: locked-down config does not silently drop them.
# tpl:
# tpl: ${MCP_SERVERS} format (string, literal JSON, may be empty or "[]"):
# tpl:   [
# tpl:     {
# tpl:       "name":    "jira",
# tpl:       "url":     "https://mcp.acme/jira",
# tpl:       "command": "/opt/mcp/jira",          # optional, stdio variant
# tpl:       "args":    ["--flag"],               # optional
# tpl:       "headers": {"Authorization":"Bearer $\{env:MCP_TOKEN\}"},
# tpl:       "env":     {"MCP_TOKEN":"$\{env:MCP_TOKEN\}"},
# tpl:       "trust":   false
# tpl:     }
# tpl:   ]

# tpl: ---------------------------------------------------------------------
# tpl: Embedded JSON payload (substituted at template-render time).
# tpl: ---------------------------------------------------------------------
MCP_SERVERS_JSON='${MCP_SERVERS}'

# tpl: tiny helpers ------------------------------------------------------
_mcp_log()  { printf '  [mcp] %s\n' "$*"; }
_mcp_warn() { printf '  [mcp][!] %s\n' "$*" >&2; }

# tpl: Pick a JSON tool: prefer jq, fall back to python3. Sets $_MCP_JSON_TOOL.
_mcp_pick_json_tool() {
    if command -v jq >/dev/null 2>&1; then
        _MCP_JSON_TOOL="jq"
    elif command -v python3 >/dev/null 2>&1; then
        _MCP_JSON_TOOL="python3"
    else
        _MCP_JSON_TOOL=""
    fi
}

# tpl: Read $MCP_SERVERS_JSON, emit one TSV row per server.
# tpl: Columns (tab-separated): name url command args_json headers_json env_json trust
# tpl: Empty fields are "-" so awk/read can keep the column count stable.
_mcp_iterate_servers() {
    local payload="$MCP_SERVERS_JSON"
    if [ "$_MCP_JSON_TOOL" = "jq" ]; then
        printf '%s' "$payload" | jq -r '
            .[] | [
                .name,
                (.url     // "-"),
                (.command // "-"),
                (.args    | if . == null then "-" else tojson end),
                (.headers | if . == null then "-" else tojson end),
                (.env     | if . == null then "-" else tojson end),
                (.trust   // false | tostring)
            ] | @tsv
        '
    else
        python3 - <<'PY_EOF'
import json, os, sys
raw = os.environ.get("MCP_SERVERS_JSON", "[]") or "[]"
try:
    data = json.loads(raw)
except Exception as e:
    sys.stderr.write("install-mcp: invalid MCP_SERVERS JSON: %s\n" % e)
    sys.exit(0)
for s in data or []:
    def col(v):
        if v is None: return "-"
        if isinstance(v, (dict, list)): return json.dumps(v)
        return str(v)
    row = [
        s.get("name", ""),
        col(s.get("url")),
        col(s.get("command")),
        col(s.get("args")),
        col(s.get("headers")),
        col(s.get("env")),
        "true" if s.get("trust") else "false",
    ]
    print("\t".join(row))
PY_EOF
    fi
}

# tpl: ---------------------------------------------------------------------
# tpl: Claude Code  —  merge into ~/.claude/settings.json (.mcpServers.<name>)
# tpl: ---------------------------------------------------------------------
_mcp_install_claude() {
    local file="$HOME/.claude/settings.json"
    [ -d "$HOME/.claude" ] || return 0
    [ -f "$file" ] || printf '{}\n' > "$file"

    local servers_payload="$MCP_SERVERS_JSON"
    export MCP_SERVERS_JSON_FOR_PY="$servers_payload"

    if [ "$_MCP_JSON_TOOL" = "jq" ]; then
        local tmp
        tmp="$(mktemp)"
        jq --argjson list "$servers_payload" '
            .mcpServers = (.mcpServers // {}) |
            reduce $list[] as $s (.;
                .mcpServers[$s.name] = (
                    if $s.url then
                        {
                            type:    "http",
                            url:     $s.url,
                            headers: ($s.headers // {}),
                            trust:   ($s.trust   // false)
                        }
                    else
                        {
                            type:    "stdio",
                            command: $s.command,
                            args:    ($s.args // []),
                            env:     ($s.env  // {}),
                            trust:   ($s.trust // false)
                        }
                    end
                )
            )
        ' "$file" > "$tmp" && mv "$tmp" "$file"
    else
        python3 - "$file" <<'PY_EOF'
import json, os, sys
path = sys.argv[1]
servers = json.loads(os.environ.get("MCP_SERVERS_JSON_FOR_PY", "[]") or "[]")
try:
    with open(path) as f:
        doc = json.load(f)
except Exception:
    doc = {}
doc.setdefault("mcpServers", {})
for s in servers:
    name = s.get("name")
    if not name:
        continue
    if s.get("url"):
        doc["mcpServers"][name] = {
            "type":    "http",
            "url":     s["url"],
            "headers": s.get("headers") or {},
            "trust":   bool(s.get("trust", False)),
        }
    else:
        doc["mcpServers"][name] = {
            "type":    "stdio",
            "command": s.get("command", ""),
            "args":    s.get("args") or [],
            "env":     s.get("env") or {},
            "trust":   bool(s.get("trust", False)),
        }
with open(path, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY_EOF
    fi
    chmod 600 "$file" 2>/dev/null || true
    unset MCP_SERVERS_JSON_FOR_PY
    _mcp_log "claude-code: wrote $(printf '%s' "$MCP_SERVERS_JSON" | _mcp_count) server(s) to $file"
}

# tpl: ---------------------------------------------------------------------
# tpl: Codex CLI  —  append [mcp_servers.<name>] sections to ~/.codex/config.toml
# tpl: Codex only supports stdio MCP servers (command/args/env).
# tpl: URL-only entries are skipped with a warning.
# tpl: ---------------------------------------------------------------------
_mcp_install_codex() {
    local file="$HOME/.codex/config.toml"
    [ -d "$HOME/.codex" ] || return 0
    [ -f "$file" ] || : > "$file"

    # tpl: Strip any previously installed managed block before re-appending,
    # tpl: so re-running the installer stays idempotent.
    local marker_start="# >>> ${CORP_SLUG} mcp >>>"
    local marker_end="# <<< ${CORP_SLUG} mcp <<<"
    if grep -qF "$marker_start" "$file" 2>/dev/null; then
        if [ "$(uname -s)" = "Darwin" ]; then
            sed -i '' "/$marker_start/,/$marker_end/d" "$file"
        else
            sed -i "/$marker_start/,/$marker_end/d" "$file"
        fi
    fi

    local block tmp_block
    tmp_block="$(mktemp)"
    {
        printf '\n%s\n' "$marker_start"
        printf '# Managed by ${CORP_NAME} launcher — do not edit by hand\n'

        local skipped=0 wrote=0
        local name url command args headers env trust
        while IFS=$'\t' read -r name url command args headers env trust; do
            [ -z "$name" ] && continue
            if [ "$command" = "-" ]; then
                _mcp_warn "codex-cli: server '$name' has no .command (URL-only). Codex requires stdio — skipped."
                skipped=$((skipped + 1))
                continue
            fi
            printf '\n[mcp_servers.%s]\n' "$name"
            printf 'command = "%s"\n' "$command"
            # tpl: emit args / env via python3 (TOML-safe quoting)
            ARGS_JSON="$args" ENV_JSON="$env" python3 - <<'PY_EOF'
import json, os, sys
def toml_str(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
args = os.environ.get("ARGS_JSON", "-")
env  = os.environ.get("ENV_JSON",  "-")
if args != "-" and args:
    try:
        a = json.loads(args)
        sys.stdout.write("args = [" + ", ".join(toml_str(str(x)) for x in a) + "]\n")
    except Exception:
        sys.stdout.write("args = []\n")
else:
    sys.stdout.write("args = []\n")
if env != "-" and env:
    try:
        e = json.loads(env)
        sys.stdout.write("env = { " + ", ".join("%s = %s" % (k, toml_str(str(v))) for k, v in e.items()) + " }\n")
    except Exception:
        pass
PY_EOF
            wrote=$((wrote + 1))
        done < <(_mcp_iterate_servers)

        printf '\n%s\n' "$marker_end"
        _mcp_log "codex-cli: wrote $wrote server(s), skipped $skipped non-stdio entry(ies)"
    } >> "$file"
    rm -f "$tmp_block"

    # tpl: Mirror allowlist in requirements.toml if present
    local req="$HOME/.codex/requirements.toml"
    if [ -f "$req" ]; then
        _mcp_update_codex_requirements "$req"
    fi
}

# tpl: Rewrite the allowed_mcp_servers = [...] line in requirements.toml.
_mcp_update_codex_requirements() {
    local req="$1"
    local names_json
    names_json="$(_mcp_names_json)"
    NAMES_JSON="$names_json" REQ_FILE="$req" python3 - <<'PY_EOF'
import json, os, re, sys
names = json.loads(os.environ.get("NAMES_JSON", "[]") or "[]")
path  = os.environ["REQ_FILE"]
try:
    with open(path) as f:
        text = f.read()
except Exception:
    sys.exit(0)
toml_list = "[" + ", ".join('"%s"' % n.replace('"','\\"') for n in names) + "]"
pattern = re.compile(r'^allowed_mcp_servers\s*=.*$', re.MULTILINE)
if pattern.search(text):
    text = pattern.sub('allowed_mcp_servers = ' + toml_list, text)
else:
    text = text.rstrip() + "\nallowed_mcp_servers = " + toml_list + "\n"
# tpl: requirements.toml is normally 0444 — chmod to write, then restore.
import stat
mode = os.stat(path).st_mode
os.chmod(path, mode | stat.S_IWUSR)
with open(path, "w") as f:
    f.write(text)
os.chmod(path, 0o444)
PY_EOF
}

# tpl: ---------------------------------------------------------------------
# tpl: Gemini CLI  —  merge into ~/.gemini/settings.json
# tpl:   .mcpServers.<name>         (the server itself)
# tpl:   .mcp.allowed[]             (allowlist mirror)
# tpl: ---------------------------------------------------------------------
_mcp_install_gemini() {
    local file="$HOME/.gemini/settings.json"
    [ -d "$HOME/.gemini" ] || return 0
    [ -f "$file" ] || printf '{}\n' > "$file"

    local servers_payload="$MCP_SERVERS_JSON"
    export MCP_SERVERS_JSON_FOR_PY="$servers_payload"

    if [ "$_MCP_JSON_TOOL" = "jq" ]; then
        local tmp
        tmp="$(mktemp)"
        jq --argjson list "$servers_payload" '
            .mcpServers = (.mcpServers // {}) |
            .mcp        = (.mcp        // {}) |
            .mcp.allowed = (.mcp.allowed // []) |
            reduce $list[] as $s (.;
                .mcpServers[$s.name] = (
                    if $s.url then
                        {
                            httpUrl: $s.url,
                            headers: ($s.headers // {}),
                            trust:   ($s.trust   // false)
                        }
                    else
                        {
                            command: $s.command,
                            args:    ($s.args // []),
                            env:     ($s.env  // {}),
                            trust:   ($s.trust // false)
                        }
                    end
                ) |
                .mcp.allowed = (.mcp.allowed + [$s.name] | unique)
            )
        ' "$file" > "$tmp" && mv "$tmp" "$file"
    else
        python3 - "$file" <<'PY_EOF'
import json, os, sys
path = sys.argv[1]
servers = json.loads(os.environ.get("MCP_SERVERS_JSON_FOR_PY", "[]") or "[]")
try:
    with open(path) as f:
        doc = json.load(f)
except Exception:
    doc = {}
doc.setdefault("mcpServers", {})
doc.setdefault("mcp", {})
doc["mcp"].setdefault("allowed", [])
for s in servers:
    name = s.get("name")
    if not name:
        continue
    if s.get("url"):
        doc["mcpServers"][name] = {
            "httpUrl": s["url"],
            "headers": s.get("headers") or {},
            "trust":   bool(s.get("trust", False)),
        }
    else:
        doc["mcpServers"][name] = {
            "command": s.get("command", ""),
            "args":    s.get("args") or [],
            "env":     s.get("env") or {},
            "trust":   bool(s.get("trust", False)),
        }
    if name not in doc["mcp"]["allowed"]:
        doc["mcp"]["allowed"].append(name)
with open(path, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY_EOF
    fi
    chmod 600 "$file" 2>/dev/null || true
    unset MCP_SERVERS_JSON_FOR_PY
    _mcp_log "gemini-cli: wrote $(printf '%s' "$MCP_SERVERS_JSON" | _mcp_count) server(s) to $file"
}

# tpl: ---------------------------------------------------------------------
# tpl: Aider / opencode — neither supports MCP natively. Warn loudly so the
# tpl: tenant operator does not assume silent success.
# tpl: ---------------------------------------------------------------------
_mcp_warn_unsupported() {
    local cli="$1"
    local names
    names="$(_mcp_names_csv)"
    [ -z "$names" ] && return 0
    _mcp_warn "$cli does not support MCP — the following servers are NOT wired for it: $names"
    _mcp_warn "$cli: use a sidecar (mcp-proxy / shell-tool) if you need these endpoints."
}

# tpl: ---------------------------------------------------------------------
# tpl: Small JSON utilities (depend on $_MCP_JSON_TOOL)
# tpl: ---------------------------------------------------------------------
_mcp_count() {
    if [ "$_MCP_JSON_TOOL" = "jq" ]; then
        jq 'length' 2>/dev/null || echo 0
    else
        python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read() or "[]")))' 2>/dev/null || echo 0
    fi
}

_mcp_names_csv() {
    if [ "$_MCP_JSON_TOOL" = "jq" ]; then
        printf '%s' "$MCP_SERVERS_JSON" | jq -r '[.[].name] | join(", ")' 2>/dev/null
    else
        printf '%s' "$MCP_SERVERS_JSON" | python3 -c \
            'import json,sys; print(", ".join(s.get("name","") for s in json.loads(sys.stdin.read() or "[]")))' 2>/dev/null
    fi
}

_mcp_names_json() {
    if [ "$_MCP_JSON_TOOL" = "jq" ]; then
        printf '%s' "$MCP_SERVERS_JSON" | jq -c '[.[].name]' 2>/dev/null
    else
        printf '%s' "$MCP_SERVERS_JSON" | python3 -c \
            'import json,sys; print(json.dumps([s.get("name","") for s in json.loads(sys.stdin.read() or "[]")]))' 2>/dev/null
    fi
}

# tpl: ---------------------------------------------------------------------
# tpl: Public entry point — called by each CLI installer.
# tpl: ---------------------------------------------------------------------
install_mcp_servers() {
    # tpl: 1. Empty / "[]" → nothing to do
    case "$MCP_SERVERS_JSON" in
        ""|"[]"|"null") return 0 ;;
    esac

    _mcp_pick_json_tool
    if [ -z "$_MCP_JSON_TOOL" ]; then
        _mcp_warn "Neither jq nor python3 found — cannot install MCP servers. Skipping."
        return 0
    fi

    # tpl: 2. Wire each CLI present on the host.
    # tpl:    The CLI is "present" if its home dir exists (created by its own
    # tpl:    installer earlier in the install.sh pipeline).
    if [ -d "$HOME/.claude" ]; then
        _mcp_install_claude
    fi
    if [ -d "$HOME/.codex" ]; then
        _mcp_install_codex
    fi
    if [ -d "$HOME/.gemini" ]; then
        _mcp_install_gemini
    fi

    # tpl: 3. Warn for CLIs that do not support MCP at all.
    case " ${WRAPPED_CLIS} " in
        *" aider "*)    _mcp_warn_unsupported "aider" ;;
    esac
    case " ${WRAPPED_CLIS} " in
        *" opencode "*) _mcp_warn_unsupported "opencode" ;;
    esac

    return 0
}
