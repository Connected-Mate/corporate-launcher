# Example — SNCF / Patrick Code / Claude Code on Bedrock (via LiteLLM)

The reference example. This is the configuration that the original Patrick Code launcher uses in production at SNCF.

## DOG answers

```json
{
  "CORP_NAME": "Patrick Code",
  "CORP_SLUG": "patrick-code",
  "CORP_POWERED_BY": "TGV Europe",
  "CORP_ORGANIZATION": "Groupe SNCF",
  "CORP_TAGLINE": "Assistant IA du groupe SNCF",
  "CORP_LICENSE_NOTE": "Usage interne SNCF — Direction IA & Innovation",

  "WRAPPED_CLIS": ["claude-code"],

  "CC_BACKEND": "LiteLLM",
  "CC_PRIMARY_URL": "https://socle.ia.sncf.fr",
  "CC_FALLBACK_URL": "https://gpt.sncf.fr/api/gateway",
  "CC_PRIMARY_MODEL": "claude-opus-4-6",
  "CC_HAIKU_MODEL": "claude-haiku-4-5",
  "CC_AUTH_MODEL": "bearer-token",
  "CC_NEEDS_STRIP_PROXY": "yes",

  "VPN_REQUIRED": "yes",
  "VPN_PROBE_URL": "https://socle.ia.sncf.fr",
  "PROXY_HOST": "web-pa-2.access.sncf.fr",
  "PROXY_PORT": "8080",
  "NO_PROXY_LIST": "127.0.0.1,localhost,.sncf.fr",
  "CA_BUNDLE_PATH": "",
  "CA_DETECT_AUTO": "yes",
  "ACCEPT_TLS_INSPECTION": "yes",

  "CYBER_AUTHORITY": "Direction Cybersécurité SNCF",
  "BLOCK_TELEMETRY": "yes",
  "BLOCK_AUTO_UPDATE": "yes",
  "BLOCK_FEEDBACK_CMDS": "yes",
  "BLOCK_VOICE_MODE": "yes",
  "COST_TRACKING_ENABLED": "yes",
  "COST_CURRENCY": "EUR",
  "PROMPT_FILTER_ENABLED": "yes",

  "BANNER_COLOR_PRIMARY": "208",
  "TERMINAL_TITLE": "Patrick Code — Powered by TGV Europe",
  "LANGUAGE": "fr",
  "FORBIDDEN_TERMS": "Claude,Claude Code,Anthropic,api.anthropic.com,claude.ai",

  "INSTALL_DIR": "~/.local/share/patrick-code",
  "BIN_PATH": "~/.local/bin",
  "LICENSE_TYPE": "Internal-only",
  "INCLUDE_UNINSTALL": "yes"
}
```

## What the user gets

After running the install:

```
~/.local/share/patrick-code/
├── patrick-code              # the wrapper (chmod +x)
├── install.sh
├── uninstall.sh
├── BRANDING.md
├── cyber-rules.md
├── settings.json
└── scripts/
    ├── vpn-check.sh
    ├── proxy-detect.sh
    ├── secrets-store.sh
    ├── strip-proxy.js
    ├── cost-tracker.py
    └── pre-tool-hook.py
```

Shell RC block added to `~/.zshrc`:

```bash
# >>> patrick-code >>>
# Patrick Code — Powered by TGV Europe
# Installed on 2026-05-16
export PATRICK_CODE_HOME="$HOME/.local/share/patrick-code"
patrick-code() { "$PATRICK_CODE_HOME/patrick-code" "$@"; }
# <<< patrick-code <<<
```

Launch:

```
$ patrick-code
  ╔═══════════════════════════════════════════════╗
  ║  Patrick Code                                 ║
  ║  Powered by TGV Europe                        ║
  ╚═══════════════════════════════════════════════╝

[patrick-code] VPN check ... OK (HTTP 401)
[patrick-code] strip-proxy listening on 127.0.0.1:9876
> _
```

## Why those answers

- **`CC_BACKEND=LiteLLM`** — the SNCF Socle IA terminates traffic at a LiteLLM proxy that forwards to AWS Bedrock. The strip-proxy is required because LiteLLM-on-Bedrock emits SSE artefacts that crash the Claude Code parser.
- **`VPN_PROBE_URL=https://socle.ia.sncf.fr`** — strictly internal domain. Returns HTTP `000` if the user is off-VPN, any other code if on-VPN. Cheaper than `ping` (no ICMP), more reliable than `nslookup` (split-DNS).
- **`ACCEPT_TLS_INSPECTION=yes`** — SNCF runs corporate SSL inspection. We can't bundle the SNCF root CA in a public skill, so we accept the relaxed-verify mode at process scope.
- **`FORBIDDEN_TERMS`** — these are blocked in every model response so an end-user demo doesn't reveal the underlying vendor.
- **`COST_CURRENCY=EUR`** — Bedrock billing is in USD but the SNCF contract bills in EUR with a fixed FX rate, so the cost-tracker uses an EUR pricing table baked in.

## Anti-patterns avoided

- We **do not** edit `/etc/hosts` to block `api.anthropic.com`. We rely on `permissions.deny` in `settings.json` plus the gateway-only `ANTHROPIC_BASE_URL`.
- We **do not** set `NODE_TLS_REJECT_UNAUTHORIZED=0` globally. The relaxed-verify is exported by the launcher process only.
- We **do not** persist the API key in the binary or in a world-readable file. macOS Keychain first, file at chmod 600 as fallback.
- We **do not** disable the `--update` machinery silently. `DISABLE_AUTOUPDATER=1` is set so the user knows the version is pinned.
