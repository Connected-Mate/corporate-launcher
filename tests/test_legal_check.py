"""Phase 1.4 — legal-check unit tests.

Covers allowed / ambiguous / forbidden paths + the --legal-reviewed and
--legal-override escape hatches + matrix freshness enforcement.
"""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

spec = importlib.util.spec_from_file_location("generate", ROOT / "scripts" / "generate.py")
generate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generate)  # type: ignore[union-attr]


def _ctx(cli: str, backend_key: str, backend_val: str) -> dict:
    return {"WRAPPED_CLIS": [cli], backend_key: backend_val}


def test_allowed_combo_passes(tmp_path: Path) -> None:
    ctx = _ctx("claude-code", "CC_BACKEND", "Bedrock")
    generate.run_legal_check(
        ctx, tmp_path,
        legal_reviewed=None, legal_reviewer=None, legal_override=None,
        dry_run=False,
    )
    attest = json.loads((tmp_path / ".legal-attestation.json").read_text())
    assert attest["findings"][0]["status"] == "allowed"


def test_forbidden_combo_blocks(tmp_path: Path) -> None:
    ctx = _ctx("claude-code", "CC_BACKEND", "openai")
    with pytest.raises(generate.GenerationError) as exc:
        generate.run_legal_check(
            ctx, tmp_path,
            legal_reviewed=None, legal_reviewer=None, legal_override=None,
            dry_run=False,
        )
    msg = str(exc.value)
    assert "FORBIDDEN" in msg
    assert "Section D.4" in msg or "competing" in msg.lower()


def test_forbidden_with_override_passes(tmp_path: Path) -> None:
    ctx = _ctx("claude-code", "CC_BACKEND", "openai")
    generate.run_legal_check(
        ctx, tmp_path,
        legal_reviewed=None, legal_reviewer=None,
        legal_override="signed exception by ACME General Counsel",
        dry_run=False,
    )
    attest = json.loads((tmp_path / ".legal-attestation.json").read_text())
    assert attest["legal_override"].startswith("signed exception")


def test_ambiguous_combo_blocks_without_review(tmp_path: Path) -> None:
    ctx = _ctx("claude-code", "CC_BACKEND", "LiteLLM")
    with pytest.raises(generate.GenerationError) as exc:
        generate.run_legal_check(
            ctx, tmp_path,
            legal_reviewed=None, legal_reviewer=None, legal_override=None,
            dry_run=False,
        )
    assert "AMBIGUOUS" in str(exc.value)


def test_ambiguous_combo_with_review_passes(tmp_path: Path) -> None:
    ctx = _ctx("claude-code", "CC_BACKEND", "LiteLLM")
    generate.run_legal_check(
        ctx, tmp_path,
        legal_reviewed="2026-05-17",
        legal_reviewer="Jane Doe <jane@acme.example>",
        legal_override=None,
        dry_run=False,
    )
    attest = json.loads((tmp_path / ".legal-attestation.json").read_text())
    assert attest["legal_reviewed"] == "2026-05-17"
    assert attest["legal_reviewer"].startswith("Jane Doe")


def test_review_date_must_be_iso(tmp_path: Path) -> None:
    ctx = _ctx("claude-code", "CC_BACKEND", "LiteLLM")
    with pytest.raises(generate.GenerationError, match="ISO date"):
        generate.run_legal_check(
            ctx, tmp_path,
            legal_reviewed="May 17 2026",
            legal_reviewer="Jane Doe <jane@acme.example>",
            legal_override=None,
            dry_run=False,
        )


def test_oss_cli_any_backend_allowed(tmp_path: Path) -> None:
    # Aider is Apache-2.0 — anything goes.
    for backend in ("openai", "anthropic", "vertex", "azure"):
        ctx = _ctx("aider", "LLM_BACKEND", backend)
        generate.run_legal_check(
            ctx, tmp_path,
            legal_reviewed=None, legal_reviewer=None, legal_override=None,
            dry_run=False,
        )
        attest = json.loads((tmp_path / ".legal-attestation.json").read_text())
        assert attest["findings"][0]["status"] == "allowed"


def test_backend_key_mapping() -> None:
    # claude-code mapping covers the common synonyms.
    assert generate._legal_backend_key("claude-code", "Bedrock") == "bedrock-anthropic"
    assert generate._legal_backend_key("claude-code", "aws-bedrock") == "bedrock-anthropic"
    assert generate._legal_backend_key("claude-code", "openai") == "openai"
    assert generate._legal_backend_key("claude-code", "Azure") == "azure-openai"
    assert generate._legal_backend_key("claude-code", "LiteLLM") == "litellm-mixed"
    assert generate._legal_backend_key("claude-code", "litellm-anthropic-only") == "litellm-anthropic-only"
    assert generate._legal_backend_key("codex-cli", "openai") == "openai"
    assert generate._legal_backend_key("codex-cli", "Azure") == "azure-openai"
    assert generate._legal_backend_key("gemini-cli", "vertex") == "vertex-gemini"
    assert generate._legal_backend_key("gemini-cli", "ai-studio") == "ai-studio-gemini"
