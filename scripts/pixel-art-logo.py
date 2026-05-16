#!/usr/bin/env python3
"""Generate ASCII / pixel-art banners for corporate launcher terminal startup.

Usage:
    python3 scripts/pixel-art-logo.py --text "ACME Copilot" --style block --color 208
    python3 scripts/pixel-art-logo.py --text "TGV" --style pixel --out banner.txt

Styles: block, slant, mini, pixel, vintage, tech, auto
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path
from typing import Iterable

# ---------------------------------------------------------------------------
# Optional pyfiglet support
# ---------------------------------------------------------------------------
try:
    import pyfiglet  # type: ignore

    HAS_PYFIGLET = True
except ImportError:  # pragma: no cover
    HAS_PYFIGLET = False


# ---------------------------------------------------------------------------
# Hand-rolled 5-row fallback font (A-Z 0-9 + space/punct)
# ---------------------------------------------------------------------------
FONT_5: dict[str, list[str]] = {
    "A": ["  ██  ", " ████ ", "██  ██", "██████", "██  ██"],
    "B": ["█████ ", "██  ██", "█████ ", "██  ██", "█████ "],
    "C": [" █████", "██    ", "██    ", "██    ", " █████"],
    "D": ["█████ ", "██  ██", "██  ██", "██  ██", "█████ "],
    "E": ["██████", "██    ", "█████ ", "██    ", "██████"],
    "F": ["██████", "██    ", "█████ ", "██    ", "██    "],
    "G": [" █████", "██    ", "██ ███", "██  ██", " █████"],
    "H": ["██  ██", "██  ██", "██████", "██  ██", "██  ██"],
    "I": ["██████", "  ██  ", "  ██  ", "  ██  ", "██████"],
    "J": ["██████", "    ██", "    ██", "██  ██", " ████ "],
    "K": ["██  ██", "██ ██ ", "████  ", "██ ██ ", "██  ██"],
    "L": ["██    ", "██    ", "██    ", "██    ", "██████"],
    "M": ["██  ██", "██████", "██████", "██  ██", "██  ██"],
    "N": ["██  ██", "███ ██", "██████", "██ ███", "██  ██"],
    "O": [" ████ ", "██  ██", "██  ██", "██  ██", " ████ "],
    "P": ["█████ ", "██  ██", "█████ ", "██    ", "██    "],
    "Q": [" ████ ", "██  ██", "██  ██", "██ ███", " █████"],
    "R": ["█████ ", "██  ██", "█████ ", "██ ██ ", "██  ██"],
    "S": [" █████", "██    ", " ████ ", "    ██", "█████ "],
    "T": ["██████", "  ██  ", "  ██  ", "  ██  ", "  ██  "],
    "U": ["██  ██", "██  ██", "██  ██", "██  ██", " ████ "],
    "V": ["██  ██", "██  ██", "██  ██", " █ █ ", "  █   "],
    "W": ["██  ██", "██  ██", "██████", "██████", "██  ██"],
    "X": ["██  ██", " █ █  ", "  █   ", " █ █  ", "██  ██"],
    "Y": ["██  ██", " █ █  ", "  █   ", "  █   ", "  █   "],
    "Z": ["██████", "    █ ", "   █  ", "  █   ", "██████"],
    "0": [" ████ ", "██  ██", "██  ██", "██  ██", " ████ "],
    "1": ["  ██  ", " ███  ", "  ██  ", "  ██  ", "██████"],
    "2": [" ████ ", "██  ██", "   ██ ", "  ██  ", "██████"],
    "3": [" ████ ", "██  ██", "   ██ ", "██  ██", " ████ "],
    "4": ["██  ██", "██  ██", "██████", "    ██", "    ██"],
    "5": ["██████", "██    ", "█████ ", "    ██", "█████ "],
    "6": [" ████ ", "██    ", "█████ ", "██  ██", " ████ "],
    "7": ["██████", "    ██", "   ██ ", "  ██  ", " ██   "],
    "8": [" ████ ", "██  ██", " ████ ", "██  ██", " ████ "],
    "9": [" ████ ", "██  ██", " █████", "    ██", " ████ "],
    " ": ["    ", "    ", "    ", "    ", "    "],
    "-": ["      ", "      ", "██████", "      ", "      "],
    "_": ["      ", "      ", "      ", "      ", "██████"],
    ".": ["    ", "    ", "    ", "    ", " ██ "],
    "!": [" ██ ", " ██ ", " ██ ", "    ", " ██ "],
    "?": [" ████ ", "██  ██", "   ██ ", "      ", "  ██  "],
    "/": ["    ██", "   ██ ", "  ██  ", " ██   ", "██    "],
}

# 2-row mini font for compact terminals
FONT_MINI: dict[str, list[str]] = {
    "A": ["╔═╗", "╠═╣"], "B": ["╔╗ ", "╚╩═"], "C": ["╔═╗", "╚═╝"],
    "D": ["╔╦╗", "═╩═"], "E": ["╔═╗", "╚═╝"], "F": ["╔═╗", "╠  "],
    "G": ["╔═╗", "╚═╣"], "H": ["╦ ╦", "╠═╣"], "I": ["╦", "╩"],
    "J": ["  ╦", "╚═╝"], "K": ["╦╔ ", "╩╚═"], "L": ["╦  ", "╩══"],
    "M": ["╔╦╗", "╩ ╩"], "N": ["╔╗╔", "╝╚╝"], "O": ["╔═╗", "╚═╝"],
    "P": ["╔╗ ", "╩  "], "Q": ["╔═╗", "╚═╣"], "R": ["╔╗ ", "╠╝ "],
    "S": ["╔═╗", "╚═╝"], "T": ["╔╦╗", " ╩ "], "U": ["╦ ╦", "╚═╝"],
    "V": ["╦ ╦", "╚╦╝"], "W": ["╦ ╦", "╚╩╝"], "X": ["╦ ╦", "╔╩╗"],
    "Y": ["╦ ╦", " ╩ "], "Z": ["╔═╗", "╚═╝"],
    " ": [" ", " "], "-": ["  ", "══"], ".": [" ", "."],
}


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
def render_fallback(text: str, font: dict[str, list[str]], rows: int) -> list[str]:
    """Render text using embedded font dict, line-by-line."""
    text = text.upper()
    lines = [""] * rows
    for ch in text:
        glyph = font.get(ch, font.get("?", [" "] * rows))
        for i in range(rows):
            lines[i] += glyph[i] + " "
    return lines


def render_pyfiglet(text: str, font_name: str) -> list[str]:
    """Render via pyfiglet; return list of lines."""
    art = pyfiglet.figlet_format(text, font=font_name)
    return [ln.rstrip() for ln in art.rstrip("\n").split("\n")]


def render_pixel(text: str) -> list[str]:
    """Pixel-art emulation: replace ██ with shaded gradient blocks."""
    base = render_fallback(text, FONT_5, 5)
    shaded = []
    palette = ["░", "▒", "▓", "█"]
    for i, line in enumerate(base):
        # Cycle shade based on row for a depth effect
        shade = palette[min(i, len(palette) - 1)]
        shaded.append(line.replace("██", shade * 2))
    return shaded


def render_vintage(text: str) -> list[str]:
    """Train-themed retro: framed banner with rails."""
    body = render_fallback(text, FONT_5, 5)
    width = max(len(line) for line in body)
    body = [line.ljust(width) for line in body]
    top = "╔" + "═" * (width + 2) + "╗"
    bot = "╚" + "═" * (width + 2) + "╝"
    rail = "─" + "═" * (width + 2) + "─"
    framed = [top] + [f"║ {line} ║" for line in body] + [bot, rail, "  o─o" + " " * (width - 6) + "o─o  "]
    return framed


def render_tech(text: str) -> list[str]:
    """Sharp angular minimalist: substitute fills with diagonal glyphs."""
    base = render_fallback(text, FONT_5, 5)
    return [line.replace("██", "▞▚") for line in base]


def render_mini(text: str) -> list[str]:
    return render_fallback(text, FONT_MINI, 2)


def render(text: str, style: str) -> list[str]:
    """Dispatch by style."""
    if style == "block":
        if HAS_PYFIGLET:
            return render_pyfiglet(text, "standard")
        print("# pyfiglet missing — fallback to embedded font. `pip install pyfiglet` for richer output.", file=sys.stderr)
        return render_fallback(text, FONT_5, 5)
    if style == "slant":
        if HAS_PYFIGLET:
            return render_pyfiglet(text, "slant")
        print("# pyfiglet missing — slant unavailable, fallback to block.", file=sys.stderr)
        return render_fallback(text, FONT_5, 5)
    if style == "mini":
        return render_mini(text)
    if style == "pixel":
        return render_pixel(text)
    if style == "vintage":
        return render_vintage(text)
    if style == "tech":
        return render_tech(text)
    raise ValueError(f"Unknown style: {style}")


# ---------------------------------------------------------------------------
# ANSI helpers
# ---------------------------------------------------------------------------
def colorize(lines: Iterable[str], color: int | None) -> list[str]:
    if color is None:
        return list(lines)
    return [f"\033[38;5;{color}m{line}\033[0m" for line in lines]


def auto_style(term_cols: int) -> str:
    if term_cols < 50:
        return "mini"
    if term_cols < 80:
        return "tech"
    if term_cols < 100:
        return "block"
    return "block"


def fit_width(lines: list[str], max_cols: int) -> list[str]:
    """Truncate or downgrade if banner exceeds terminal width."""
    width = max((len(strip_ansi(ln)) for ln in lines), default=0)
    if width <= max_cols:
        return lines
    # Try mini fallback
    return [ln[:max_cols] for ln in lines]


def strip_ansi(s: str) -> str:
    out = []
    i = 0
    while i < len(s):
        if s[i] == "\033":
            while i < len(s) and s[i] != "m":
                i += 1
            i += 1
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Generate ASCII / pixel-art banners for corporate launcher startup.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Styles: block, slant, mini, pixel, vintage, tech, auto",
    )
    p.add_argument("--text", required=True, help="Brand text to render.")
    p.add_argument(
        "--style",
        default="auto",
        choices=["block", "slant", "mini", "pixel", "vintage", "tech", "auto"],
        help="Banner style (default: auto — picks based on terminal width).",
    )
    p.add_argument(
        "--color",
        type=int,
        default=None,
        help="ANSI 256-color code (0-255). Omit for no color.",
    )
    p.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Write to file instead of stdout (color stripped if file).",
    )
    p.add_argument(
        "--max-cols",
        type=int,
        default=None,
        help="Override max columns (defaults to terminal width).",
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()
    term_cols = args.max_cols or shutil.get_terminal_size((80, 24)).columns
    style = auto_style(term_cols) if args.style == "auto" else args.style

    try:
        lines = render(args.text, style)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    lines = fit_width(lines, term_cols)

    if args.out:
        # No color in file output
        args.out.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"# wrote {len(lines)} lines to {args.out}", file=sys.stderr)
        return 0

    colored = colorize(lines, args.color)
    print("\n".join(colored))
    return 0


if __name__ == "__main__":
    sys.exit(main())
