# MCP + Aider — limitation & workarounds

**Status (May 2026):** Aider has **no native MCP support**. The upstream CLI
does not speak the Model Context Protocol, does not expose tool-calling, and
will not auto-discover MCP servers. Open issues confirm it
([#3314](https://github.com/Aider-AI/aider/issues/3314),
[#2672](https://github.com/Aider-AI/aider/issues/2672),
[#4506](https://github.com/aider-ai/aider/issues/4506)). The MCP servers
*named* "aider-mcp-server" go the **other direction**: they let an MCP client
(Claude, Cursor) drive Aider — not the reverse.

## Workarounds

If a tenant sets `SKILLS_MODE` to include MCP and `CLI=aider`, two options
exist — both out-of-tree, both **unsupported** by the launcher:

1. **MCP-to-OpenAI gateway.** Run a bridge such as
   [`MCP-Bridge`](https://github.com/SecretiveShell/MCP-Bridge) or
   [`mcpm-aider`](https://github.com/lutzleonhardt/mcpm-aider). The bridge
   exposes MCP tools behind an OpenAI-compatible `/v1/chat/completions`
   endpoint with function-calling. Point Aider at the bridge by overriding
   `OPENAI_API_BASE` to the bridge URL instead of the corporate gateway —
   note this **breaks the single-gateway audit trail** and is therefore
   forbidden by most corporate policies.

2. **Pre-fetch + `--read`.** Wrap `aider` in a shell script that calls MCP
   servers up-front (via `mcp-cli` or a thin Python script), dumps the
   retrieved context to a temp file, and passes it as
   `aider --read /tmp/mcp-ctx.md ...`. Read-only, no tool execution, but
   keeps the corporate gateway path intact.

## Required install-time warning

In `templates/aider/install.sh.tpl`, after resolving `SKILLS_MODE`, emit:

```sh
if echo "${SKILLS_MODE}" | grep -qi mcp; then
    warn "Aider has no native MCP support (May 2026)."
    warn "MCP-flagged skills will be installed as docs only."
    warn "See references/mcp-aider-note.md for bridge options."
fi
```

The launcher itself stays MCP-agnostic — Aider receives no MCP env vars.
