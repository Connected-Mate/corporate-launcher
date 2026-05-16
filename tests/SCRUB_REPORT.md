# Scrub Report

Comprehensive removal of tenant-specific references (SNCF, Patrick Code, TGV Europe, Socle IA, Direction Cybersécurité, DOG acronym) from the corporate-launcher repo. Final grep across the working tree returns zero matches for the full pattern.

## Files touched

- `tests/test_render.py` — fixture context and assertions replaced (`Patrick Code` -> `Acme Copilot`, `patrick-code` -> `acme-copilot`, `TGV Europe` -> `Acme AI Lab`, `SNCF` -> `Acme Corp`, `Direction Cybersecurite SNCF` -> `Corporate Security Office`).
- `tests/branding/eval_prompts.json` — placeholder examples in the schema description neutralized to `Acme Copilot` / `Acme Corp` / `Acme AI Lab`.
- `tests/test_generate.py` — docstring (`dog.json` -> `config.json`, `DOG JSON config` -> `JSON config`), fixture filename references and `socle.ia.acme.internal` -> `gateway.acme.internal`.
- `schema/config.schema.json` — `$id` URL `github.com/sncf/...` -> `github.com/example/...`.
- `scripts/interview.py` — removed `Powered by TGV Europe.` trailer; `dog.json` defaults -> `config.json`.
- `scripts/render.py` — `dog.json` usage examples -> `config.json`; docstrings and arg help reference `interview answers` instead of `DOG answers`.
- `scripts/generate.py` — pipeline docstring, CLI help, and `validate_dog` -> `validate_config`; all `dog.json` -> `config.json`; `DOG validation failed:` -> `Config validation failed:`.
- `reference/interview-flow.md` — example URL `socle.ia.acme.fr` -> `gateway.acme.example`.

## Verification

Final grep `(SNCF|Patrick.{0,5}Code|\bPatrick\b|TGV.{0,5}Europe|\bTGV\b|Socle.{0,5}IA|Direction.{0,5}Cyber|patrick-code|sncf|tgv-europe|socle\.ia|cybersecurite|\bdog\b|\bDOG\b)` returns 0 matches outside `.git/` / `.pytest_cache/`. No French-accented characters remain in `*.md` / `*.tpl` / `*.json` sources.
