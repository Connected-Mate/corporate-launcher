# URL Purge — vendor endpoint stripper

Post-render scanner that guarantees no vendor public endpoint (api.anthropic.com, api.openai.com, sentry.io, datadog, ...) ever leaks into the rendered launcher tree. Build-time half of the corporate launcher's defense-in-depth posture; the runtime half is the cyber-guard PreToolUse hook.

## 1. Why this exists — defense in depth

A corporate launcher routes every LLM call through `gateway.acme.example`. Direct vendor URLs in launcher files are a problem because:

- A user editing `settings.json` later could copy-paste `api.anthropic.com` from a template and bypass the proxy.
- A CI/CD pipeline could scrape generated artifacts and surface forbidden domains.
- A leaked launcher tarball could carry endpoints that contradict the cyber policy.

The rule: **vendor URLs may only appear in `permissions.deny` arrays, template comments, or documentation sections that explicitly describe what is blocked**. Anywhere else is a violation, even if the URL is currently unused.

## 2. What's blocked

The authoritative list lives in `templates/shared/url-purge-list.json`. As of v6:

- ~110 exact domains across categories: `llm-api`, `llm-web`, `llm-platform`, `telemetry`, `error-telemetry`, `product-analytics`, `session-replay`, `infra-telemetry`, `feature-flags`, `package-registry`, `marketplace`, `updates`, `auth`, `ide-api`.
- ~30 regex patterns for subdomain wildcards (e.g. `.*\.anthropic\.com/.*`, `.*\.ingest\.sentry\.io/.*`) and for embedded secrets in URLs (`sk-[A-Za-z0-9]{20,}`, `sk-ant-...`).
- Representative vendors: Anthropic, OpenAI, Google Gemini, Mistral, Cohere, Groq, Perplexity, DeepSeek, xAI, Together, Fireworks, Replicate, Hugging Face, OpenRouter, Cursor, Cline, Continue.dev, Codeium/Windsurf, Tabnine, GitHub Copilot, Aider, LangSmith, Langfuse, Helicone, Portkey, Braintrust, W&B, Sentry, Statsig, GrowthBook, Segment, Amplitude, Mixpanel, PostHog, Heap, FullStory, Hotjar, LogRocket, Datadog, New Relic, Honeycomb, Bugsnag, Rollbar, Raygun, Intercom, LaunchDarkly, Split.io, Optimizely, VSCode marketplace, Open VSX, npm, PyPI.

Also recorded: `allowed_corp_endpoints` — `gateway.acme.example`, `nexus.acme.example`, `github.com`, `api.github.com`, `raw.githubusercontent.com`. These never trigger a violation.

## 3. Allowed contexts (verdict: OK)

The scanner classifies each URL match into one of four verdicts:

| Verdict | Trigger | File types |
|---|---|---|
| `OK (deny list)` | URL appears inside a JSON `"deny"` array | `settings.json`, `settings.local.json` |
| `OK (comment)` | Line starts with `#`, `//`, `--`, `;`, `/*`, or `*` (after stripping whitespace) | any |
| `OK (doc)` | URL appears beneath an `.md` heading containing `not allowed`, `blocked`, `denied`, `forbidden`, `interdit`, or `bloque` | `.md` |
| `VIOLATION` | none of the above | any |

The `always_allowed_in` field of `url-purge-list.json` lists conventional paths exempted by policy (e.g. `cyber-rules.md`, `BRANDING.md`, `tests/fixtures/*`, `docs/*`).

## 4. Usage

### Automatic (recommended)

`scripts/generate.py` invokes the purge as its final step:

```python
# already wired in generate.py
subprocess.run([
    sys.executable, "scripts/url-purge.py",
    "--launcher-dir", out_dir,
    "--config", config_path,
    "--strict",
], check=True)
```

If `--strict` is set, the exit code equals the number of violations — `generate.py` aborts and refuses to ship.

### Manual scan (read-only)

```bash
python3 scripts/url-purge.py \
    --launcher-dir dist/my-launcher \
    --config config.json \
    --report purge-report.md
```

Prints a console table and (with `--report`) writes a Markdown report listing every match and its verdict.

### Manual patch (rewrites the tree)

```bash
python3 scripts/url-purge.py \
    --launcher-dir dist/my-launcher \
    --config config.json \
    --patch
```

For each violation, the offending URL is replaced in place with the sentinel `[BLOCKED-VENDOR-URL]`. Each modified file is backed up alongside as `<file>.bak`. Run again without `--patch` to confirm zero violations remain.

## 5. False positive handling

If a legitimate use surfaces (new corp tool, exempted doc page), do **not** silence the scanner per-file. Instead:

1. Open `templates/shared/url-purge-list.json`.
2. Add the path glob to `always_allowed_in` if the whole file should be exempt, **or** add the corp endpoint to `allowed_corp_endpoints` if a domain should never be flagged.
3. Re-run `python3 scripts/url-purge.py ... --report` to confirm.
4. Commit with a justification message (the file is also reviewed by Cyber).

If the false positive is a comment that the heuristic missed (e.g. a multi-line YAML comment), prefer reformatting the comment so it starts with `#` on the same line as the URL — that is cheaper than loosening the classifier.

## 6. Integration with cyber-guard (runtime defense)

`templates/shared/pre-tool-hook.py.tpl` (the cyber-guard) reads the same `url-purge-list.json` at runtime and blocks `fetch` / `WebFetch` / `Bash(curl)` / `Bash(wget)` calls whose target matches the blocklist. Together:

- **Build time** (`url-purge.py`): no vendor URL exists in launcher source files.
- **Run time** (`pre-tool-hook`): even if a user pastes one into a chat or a tool argument, the call is denied before it leaves the workstation.

Both layers share the JSON, so updating the blocklist updates both.

## 7. Limitations

The scanner is intentionally string-based and will **not** catch:

- Base64-, hex-, or rot13-encoded URLs.
- URLs assembled at runtime (`"api." + "anthropic" + ".com"`).
- URLs broken across multiple lines (e.g. backslash continuations inside shell scripts).
- Domain typosquats not in the list (`api.anthropic.co`, `api-openai.com`).
- URLs hidden in binary assets (PNGs, fonts, sqlite blobs).

For those, rely on the runtime hook plus the corporate egress proxy. The purge is a guard, not a sandbox.

## 8. CI integration

Drop this step into `.github/workflows/build-launcher.yml` (or the GitLab equivalent):

```yaml
- name: URL purge (vendor endpoint check)
  run: |
    python3 scripts/url-purge.py \
        --launcher-dir dist/${{ matrix.launcher }} \
        --config configs/${{ matrix.launcher }}.json \
        --report purge-report.md \
        --strict
- name: Upload purge report
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: url-purge-report-${{ matrix.launcher }}
    path: purge-report.md
```

`--strict` returns the violation count as the exit code, so a single hit fails the job. The Markdown report is uploaded on success and failure so reviewers always see the verdict table.
