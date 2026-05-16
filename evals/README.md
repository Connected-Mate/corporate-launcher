# Evals — corporate-launcher

This directory holds evaluation suites that score the **skill itself**, not the launchers it generates.

> **Don't confuse with `tests/branding/`** — that suite verifies the *generated* launcher (rendered files, branding scrub, smoke tests). `evals/` instead asks: *does Claude correctly invoke this skill, and does it produce a good launcher when invoked?*

---

## Why two eval files

| File | Question it answers | Workflow |
|---|---|---|
| `evals.json` | When invoked, does the skill deliver a usable launcher? | `skill-creator` aggregate benchmark |
| `trigger-eval.json` | Does Claude correctly **decide** to invoke the skill from a free-form user query? | local trigger-optimization loop |

### `evals.json` — invocation eval

A list of realistic user prompts (each one a full conversational opener like *"build me a white-label cli that wraps codex on our azure openai"*). Each case is run end-to-end against the skill in a fresh sandbox, and the resulting launcher tree is graded against pass criteria (branding scrubbed, gateway wired, install scripts present, smoke tests green).

Used by skill-creator's `aggregate_benchmark` workflow, which runs each case N times and reports mean / variance — variance matters because skill behaviour is non-deterministic.

### `trigger-eval.json` — trigger eval

A flat array of 20 short user queries, each tagged `should_trigger: true|false` and annotated with a one-line `note`. Half of them describe legitimate corporate-launcher intent (internal LiteLLM, regulated org, "ship to my team"); the other half are adjacent distractors that look related but are not (general model comparison, personal install help, ad-hoc OpenAI script, Vertex provisioning, etc.).

The goal: tune the `description:` field in `SKILL.md` until precision and recall on this set are both high.

---

## How to run the invocation eval

```bash
# from anywhere
python -m scripts.run_loop \
  --skill /Users/0104389S/Documents/skills/corporate-launcher \
  --eval evals/evals.json \
  --n 5 \
  --report out/eval-report.json
```

See the skill-creator runbook (`document-skills:skill-creator`) for the canonical pipeline, including how to:

- shard cases across workers
- diff a candidate `SKILL.md` against the baseline
- compute variance and statistical confidence

Each case is graded by an LLM judge that loads the generated launcher tree and answers a fixed rubric (does it run, does it scrub vendor branding, does it bind to the right gateway, are the install scripts complete).

## How to run the trigger eval

```bash
python -m scripts.trigger_loop \
  --skill /Users/0104389S/Documents/skills/corporate-launcher \
  --eval evals/trigger-eval.json \
  --judge sonnet \
  --report out/trigger-report.json
```

The loop:

1. Reads each `query` and asks the judge model: *"Given this skill description, would you invoke the skill?"*
2. Compares to `should_trigger`.
3. Reports a confusion matrix.
4. If accuracy is below threshold, suggests targeted edits to the `description:` field (add a phrase, remove a misleading anti-trigger, tighten the scope).

This loop is what shaped the current `description:` — including the explicit "trigger phrases include …" enumeration and the anti-trigger about hobby setups.

---

## Pass criteria

### Invocation eval (`evals.json`)
- **≥ 80%** of cases produce a launcher that passes `tests/branding/` automatically
- **0** cases leak vendor branding (Claude / Codex / Gemini / Anthropic / OpenAI / Google in user-facing strings)
- **0** cases write to the wrong gateway (Bedrock when user said Vertex, etc.)
- mean score variance across runs **≤ 0.15** (stable behaviour)

### Trigger eval (`trigger-eval.json`)
- **≥ 90% recall** on `should_trigger: true` (the skill fires when it should)
- **≤ 10% false-positive rate** on `should_trigger: false` (the skill does *not* fire on distractors)
- No single distractor category (model comparison, personal install, SDK building, GCP provisioning) accounts for more than one false positive

If either threshold is missed, do **not** ship the new `SKILL.md` — iterate.

---

## Adding new eval cases

### Trigger eval

Append an object to `trigger-eval.json`:

```json
{
  "query": "<verbatim user message, can be messy / lowercase / typo'd>",
  "should_trigger": true,
  "note": "<one-line justification — what about the query makes it (not) match>"
}
```

Conventions:

- Keep `query` realistic — paste actual things colleagues have asked, don't sanitize
- Aim for a ~50/50 split between `true` and `false`
- For each new `should_trigger: false`, pick a *plausible distractor* — something a worse skill description would over-trigger on
- Cap the file at ~40 entries; beyond that, split into themed shards (`trigger-eval-gateway.json`, `trigger-eval-cli.json`)

### Invocation eval

Append an object to `evals.json`:

```json
{
  "id": "vertex-eu-residency",
  "query": "<realistic user opener>",
  "expected": {
    "gateway": "vertex",
    "wrapped_cli": "gemini",
    "branding_scrubbed": true,
    "ships_install_script": true
  },
  "note": "<scenario justification>"
}
```

Add a new case when:

- a real user request hits a code path not yet covered (new gateway, new CLI, new corporate constraint)
- a regression is found in production — encode it as a case **before** fixing, then verify the fix
- a new policy lands (e.g., FIPS endpoints, GovCloud) and needs guardrails

Naming: kebab-case `id` that reads as `<gateway>-<distinctive-constraint>` (e.g., `bedrock-fips`, `azure-ca-bundle`, `litellm-fleet-40`).

---

## CI integration

Example GitHub Actions step (drop into `.github/workflows/skill-eval.yml`):

```yaml
name: skill-eval
on:
  pull_request:
    paths:
      - 'SKILL.md'
      - 'templates/**'
      - 'scripts/**'
      - 'evals/**'

jobs:
  trigger-eval:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: '3.12' }
      - run: pip install -e .[dev]
      - name: Trigger eval (cheap, runs on every PR)
        run: |
          python -m scripts.trigger_loop \
            --skill . \
            --eval evals/trigger-eval.json \
            --judge sonnet \
            --fail-under 0.90 \
            --report trigger-report.json
      - uses: actions/upload-artifact@v4
        with:
          name: trigger-report
          path: trigger-report.json

  invocation-eval:
    runs-on: ubuntu-latest
    # heavier — only on label or main
    if: contains(github.event.pull_request.labels.*.name, 'run-full-eval')
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: '3.12' }
      - run: pip install -e .[dev]
      - name: Aggregate benchmark
        run: |
          python -m scripts.run_loop \
            --skill . \
            --eval evals/evals.json \
            --n 3 \
            --fail-under 0.80 \
            --report eval-report.json
      - uses: actions/upload-artifact@v4
        with:
          name: eval-report
          path: eval-report.json
```

Recommendation: gate every PR on `trigger-eval` (cheap, ~30s), gate `invocation-eval` behind a `run-full-eval` label or run it nightly on `main`.

---

## See also

- `tests/branding/` — verifies the **output** launcher
- `references/` — the design vocabulary the skill renders against
- `document-skills:skill-creator` — canonical eval runbook for all skills in this monorepo
