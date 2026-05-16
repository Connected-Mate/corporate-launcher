# Pixel-Art Logo — Banner Step Reference

The pixel-art logo step gives every corporate launcher a memorable, branded
startup banner — the first impression developers see when they fire up their
terminal copilot. Rendered by `scripts/pixel-art-logo.py` and wired into
`templates/banner/banner.sh.tpl`, it turns a plain `CORP_NAME` into ASCII art
with optional 256-color tint and a heart footer.

## 1. Purpose

A branded banner builds trust and recall on every shell session. It signals
"this is *our* internal tool, not raw upstream" without nagging the user. The
step is opt-in via `BANNER_STYLE` but on by default — silence is boring.

## 2. The six styles

| Style     | One-liner                                                       |
|-----------|-----------------------------------------------------------------|
| `block`   | Solid 5-row `██` glyphs — bold, corporate, the safe default.    |
| `slant`   | Italic figlet variant — needs `pyfiglet`, falls back to block.  |
| `mini`    | 2-row box-drawing glyphs — compact for narrow terminals.        |
| `pixel`   | Shaded gradient blocks (`░▒▓█`) — retro 8-bit feel.             |
| `vintage` | Block art framed with rails + `o─o` train wheels — SNCF flavor. |
| `tech`    | Diagonal `▞▚` fills — sharp, angular, minimalist.               |

## 3. Visual examples (`ACME COPILOT`)

`block`:
```
  ██   ██████ ██  ██ ██████     ██████ █████   █████  ██ ██     █████  █████
 ████  ██     ███ ██ ██         ██     ██  ██ ██   ██ ██ ██    ██   ██   ██
██████ ██     ██████ █████      ██     ██  ██ ██████  ██ ██    ██   ██   ██
██  ██ ██     ██ ███ ██         ██     ██  ██ ██      ██ ██    ██   ██   ██
██  ██ ██████ ██  ██ ██████     ██████ █████  ██      ██ ██████ █████    ██
```

`mini`:
```
╔═╗ ╔═╗ ╔╦╗ ╔═╗   ╔═╗ ╔═╗ ╔╗  ╦ ╦  ╔═╗ ╔╦╗
╠═╣ ╚═╝ ╩ ╩ ╚═╝   ╚═╝ ╚═╝ ╩   ╚═╝  ╚═╝  ╩
```

`pixel` (depth-shaded rows):
```
░░ ░░░░░░ ░░  ░░ ░░░░░░  ...
▒▒ ▒▒     ▒▒▒ ▒▒ ▒▒      ...
▓▓ ▓▓     ▓▓▓▓▓▓ ▓▓▓▓▓   ...
██ ██     ██ ███ ██      ...
██ ██████ ██  ██ ██████  ...
```

`vintage` (framed + rails):
```
╔═══════════════════════════════╗
║  ACME COPILOT block art here  ║
╚═══════════════════════════════╝
─═══════════════════════════════─
  o─o                       o─o
```

`tech` (diagonal fills replace `██` with `▞▚`).

## 4. Auto-style

If `--style auto` (or `BANNER_STYLE=auto`), Python picks based on terminal
width: `<50` → `mini`, `<80` → `tech`, otherwise `block`. The bash template
uses similar thresholds (`>100` block, `≥60` slant, else mini) when resolving
on the shell side before invoking Python — keeps narrow tmux panes legible.

## 5. Color

ANSI 256-color codes via `--color N` (0-255). The banner emits
`\033[38;5;Nm…\033[0m` per line. Recommended brand colors: `208` (SNCF
orange), `33` (corporate blue), `196` (alert red). Color is stripped when
writing to a file (`--out`) so cached banners stay paste-safe.

## 6. Usage

**Manual / preview:**
```bash
python3 scripts/pixel-art-logo.py --text "ACME COPILOT" --style block --color 208
python3 scripts/pixel-art-logo.py --text "TGV" --style vintage --color 208 --out banner.txt
```

**Inside the launcher** — `show_corp_banner()` in
`templates/banner/banner.sh.tpl` calls the script with values substituted at
install time:
```bash
python3 "${INSTALL_DIR}/scripts/pixel-art-logo.py" \
    --text  "${CORP_NAME}" \
    --style "${BANNER_STYLE}" \
    --color "${BANNER_COLOR_PRIMARY}"
```
If Python or the script is missing, the bash template degrades gracefully via
its own `__corp_banner_fallback_*` ASCII frames (one per style).

## 7. Customization — adding a new style

1. Add a `FONT_*` dict to `scripts/pixel-art-logo.py` (rows of equal length)
   *or* a `render_<style>()` function that transforms `FONT_5` output.
2. Register the style in the `render()` dispatcher and in the argparse
   `choices=[…]` list.
3. Add a matching `__corp_banner_fallback_<style>()` in `banner.sh.tpl` so
   pyfiglet-less hosts still degrade nicely.
4. Update `auto_style()` thresholds if the new style targets a specific width.

## 8. Fallback chain

- **pyfiglet present** → used for `block` (font `standard`) and `slant`.
- **pyfiglet absent** → embedded `FONT_5` (A-Z, 0-9, space, `-_.!?/`) covers
  block; slant degrades to block with a stderr notice. `mini` uses `FONT_MINI`
  (2-row box-drawing) regardless. `pixel`, `vintage`, `tech` all build on
  `FONT_5`, so they work fully offline.
- **Python missing entirely** → bash fallbacks (`+----+ | NAME | +----+`-style
  frames) keep the launcher functional on minimal images.

## 9. Performance

Embedded-font rendering is pure string concat — runs in <50 ms on a cold
Python interpreter. pyfiglet adds ~30 ms. Output is cached at
`${INSTALL_DIR}/banner.txt` (color stripped) so subsequent shells can `cat`
the file instead of re-invoking Python — useful when the launcher is sourced
on every prompt.

## 10. The heart footer

The launcher's `show_corp_banner()` appends a heart footer after the banner
art and identity block:
```
  Made with ♥ by <CORP_POWERED_BY>
```
The `♥` glyph is rendered in red even when the rest of the banner uses
`BANNER_COLOR_PRIMARY` — a small, deliberate moment of warmth.
`templates/banner/footer.sh.tpl` provides an alternate variant
(`Made for friends · Made from France with ❤`) for community editions.
