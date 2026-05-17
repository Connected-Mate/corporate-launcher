# Legal compatibility matrix — CLI × backend

> **Last read: 2026-05-17.** Terms of service evolve. **Re-verify every 6 months** or before any new corporate deployment. This document is operational guidance for the launcher generator, **not a legal opinion**. Legal review is required for every "ambiguous" cell and for any commercial deployment.

---

## Why this matters for corporates

The launcher wraps **7 public AI coding CLIs** around corporate AI gateways. Each CLI is published by a vendor whose terms of service constrain what models can legitimately be reached through the CLI:

- **Vendor-published CLIs** (Claude Code / Codex CLI / Gemini CLI) carry restrictive commercial clauses: they may not be used to "build a competing product" or "develop competing AI models". Pointing a vendor's CLI at a competitor's API is the textbook case for a "competing service" interpretation. See the public incident of Aug 2025 — Anthropic revoked OpenAI's Claude API access citing exactly this clause.
- **OSS-published CLIs** (Aider / opencode / Continue.dev / Cline) are Apache-2.0 or MIT licensed and impose **no restriction on which model backend the user wires up**. The legal risk shifts to the **backend provider's terms** (OpenAI Services Agreement, Anthropic Commercial Terms, etc.).
- Corporates deploying the launcher get a configuration matrix that, if mis-set, can put them in breach of a vendor's terms without any code change visible to legal. The launcher MUST refuse to generate such configurations.

Two failure modes corporates must avoid:

1. **CLI-side breach** — wiring a vendor CLI to a competitor backend. Example: `claude` CLI → OpenAI gateway. Anthropic Commercial Terms §D.4 makes this defensible-as-breach.
2. **Backend-side breach** — using a backend in a way the backend vendor forbids. Example: using OpenAI output to fine-tune an Anthropic-compatible model. OpenAI Services Agreement forbids this independently of which CLI is used.

This document covers (1). Backend-side breach is out of scope but flagged where it overlaps.

---

## Per-CLI analysis

### 1. Claude Code (Anthropic)

- **TOS sources** read on **2026-05-17**:
  - https://www.anthropic.com/legal/commercial-terms (Commercial Terms)
  - https://www.anthropic.com/legal/consumer-terms (Consumer Terms, §3, §13)
  - https://www.anthropic.com/legal/aup (Usage Policy)
  - https://code.claude.com/docs/en/third-party-integrations (officially supported deployment options)
- **License of the CLI itself**: Anthropic proprietary (not open source). Source visibility limited; reverse-engineering has triggered DMCA takedowns (TechCrunch, Apr 2025).
- **Key clauses cited verbatim**:
  - **Commercial Terms §D.4 (Use Restrictions)**: *"Customer may not and must not attempt to (a) access the Services to build a competing product or service, including to train competing AI models or resell the Services except as expressly approved by Anthropic"*.
  - **Consumer Terms §3**: *"To develop any products or services that compete with our Services, including to develop or train any artificial intelligence or machine learning algorithms or models or resell the Services."* (prohibited)
  - **Consumer Terms §13 (Use of our brand)**: trademark / "Claude Code" name may not be used in connection with non-Anthropic products without written permission.
  - **Usage Policy ("Do Not Abuse")**: *"Utilization of inputs and outputs to train an AI model (e.g., 'model scraping' or 'model distillation') without prior authorization from Anthropic"*.
- **Officially supported backends** (per `code.claude.com/docs/en/third-party-integrations`, 2026-05-17): Claude for Teams/Enterprise, Anthropic Console, **Amazon Bedrock**, **Claude Platform on AWS**, **Google Vertex AI**, **Microsoft Foundry**. **All host Anthropic / Claude models.** No mention of OpenAI, Gemini, Mistral, or any non-Anthropic provider as a supported backend. LLM gateways are supported only via `ANTHROPIC_BASE_URL`, `ANTHROPIC_BEDROCK_BASE_URL`, `ANTHROPIC_VERTEX_BASE_URL`, `ANTHROPIC_FOUNDRY_BASE_URL` — all Anthropic-routed.
- **Public incidents reinforcing the reading**:
  - Aug 2025: Anthropic revoked OpenAI's Claude API access for using "coding tools" ahead of GPT-5 release, citing the Commercial Terms competing-product clause (The Register, VentureBeat, Slashdot).
  - Apr 2026 OpenClaw policy: third-party harnesses connecting Claude.ai subscriptions through non-API channels were banned (reversed May 2026 with Agent SDK credits).
- **Verdict on the 5 questions**:
  1. Talk to a competitor model? **Forbidden in practice** for OpenAI / Gemini / any non-Anthropic model. Anthropic-hosted-on-Vertex or Anthropic-hosted-on-Bedrock are explicitly supported. Routing Claude Code to GPT-4/GPT-5 is the canonical "competing product" case.
  2. Rebranded / white-labeled? **Forbidden** without written permission. Consumer Terms §13 + Commercial Terms §D.4 resale ban.
  3. Competing-services clause? **Yes, explicit.** Commercial Terms §D.4.
  4. Audit / logs? §D.2 requires cooperation with "reasonable requests for information" but no dedicated logging mandate.
  5. Personal vs commercial vs enterprise? **Yes.** Consumer Terms (Claude.ai) vs Commercial Terms (API / Bedrock / Vertex / Foundry) vs Teams/Enterprise plans. Enterprise plans add SSO, managed permissions, compliance API but do **not** relax the competing-models restriction.

### 2. Codex CLI (OpenAI)

- **TOS sources** read on **2026-05-17**:
  - https://openai.com/policies/services-agreement/ (returned 403 to WebFetch; content confirmed via multiple secondary sources including TermsFeed analysis and OpenAI's published policy index)
  - https://openai.com/policies/row-business-terms (403, confirmed via search-result quotations)
  - https://openai.com/policies/usage-policies/ (403, partial via search)
  - https://github.com/openai/codex/blob/main/LICENSE → **Apache 2.0**.
- **License of the CLI itself**: **Apache 2.0** — fully open source, permissive, includes patent grant. Significantly more permissive than Claude Code.
- **Key clauses cited verbatim** (OpenAI Services Agreement, "Use of Services" section, per public summaries 2026-05-17):
  - *"Customer may not use Output to develop artificial intelligence models that compete with our products and services"* — with a **Permitted Exception**: *"to develop models primarily intended to categorize, classify, or organize data (e.g., embeddings or classifiers), if these models are not distributed or made commercially available to third parties, and to fine tune or customize models provided as part of OpenAI's fine-tuning or other Services."*
  - Reflected in row-Terms-of-Use: *"users are prohibited from using Output to develop models that compete with OpenAI."*
- **Practical reading for CLI wiring**: the Apache-2.0 license on the CLI **client** means corporates can fork, rebrand, audit, redistribute the CLI itself. OpenAI accepted upstream PRs adding Anthropic backend support (LinkedIn, MindStudio, Apr 2025). So Codex CLI → Anthropic backend is **upstream-blessed**. The OpenAI Services Agreement restriction is on **the use of OpenAI output** to train competitors — it does **not** apply when the CLI is pointed at a non-OpenAI backend (no OpenAI output is generated in that path).
- **Verdict on the 5 questions**:
  1. Talk to a competitor model? **Allowed** — upstream-supported (Anthropic, others). Caveat: if the user *also* uses the CLI with OpenAI in another session and then uses outputs to train a competing model, that's a backend-side breach independent of the CLI choice.
  2. Rebranded / white-labeled? **Allowed by Apache 2.0** — must preserve NOTICE/LICENSE files and copyright attribution.
  3. Competing-services clause? **Only on Output usage**, not on the CLI binary or on which backend it talks to.
  4. Audit / logs? OpenAI logs API usage on its side; nothing in the CLI Apache 2.0 license imposes audit on the client side.
  5. Personal vs commercial vs enterprise? OpenAI distinguishes Consumer Terms vs Business Terms vs Enterprise Agreement. Enterprise Agreement typically adds zero-retention options. Codex CLI itself is the same binary across tiers.

### 3. Gemini CLI (Google)

- **TOS sources** read on **2026-05-17**:
  - https://policies.google.com/terms/generative-ai (legacy text, superseded 2024-05-22 unless signed business agreement references it)
  - https://cloud.google.com/terms/ (GCP main terms, §3.1, §3.3, §4.1, §4.3, §5.4)
  - https://cloud.google.com/terms/aiml-models (404 on 2026-05-17 — superseded)
  - https://docs.cloud.google.com/vertex-ai/generative-ai/docs/partner-models/use-partner-models (Vertex partner-models doc)
  - https://github.com/google-gemini/gemini-cli/blob/main/LICENSE → **Apache 2.0**.
- **License of the CLI itself**: **Apache 2.0**.
- **Key clauses cited verbatim**:
  - Legacy Generative AI Terms (Aug 2023): *"You may not use the Services to develop machine learning models or related technology."* — now superseded for most commercial use by GCP main terms + service-specific terms.
  - GCP Terms §4.3 (Generative AI Safety and Abuse): *"Google uses automated safety tools to detect abuse of Generative AI Services. […] if these tools detect potential abuse or violations of Google's AUP or Prohibited Use Policy, Google may log Customer prompts solely for the purpose of reviewing and determining whether a violation has occurred."*
  - Vertex partner-models doc (Anthropic Claude on Vertex): *"Anthropic enforces policies that prohibit certain resellers from reselling their products. If your Google Cloud billing account is managed by a prohibited reseller, you will be unable to accept the Terms of Service or enable Claude models."*
- **Practical reading**: Apache-2.0 CLI binary itself is reusable / forkable. **Documentation explicitly focuses on Gemini models only**, and the CLI's streaming protocol is **incompatible with non-Gemini Vertex partner models** without patches (gemini-cli GitHub issue #25579, LiteLLM PR #12246 — bug fixes published Apr 2026 but not officially supported). Pointing Gemini CLI at OpenAI is technically possible via LiteLLM but not endorsed by Google.
- **Verdict on the 5 questions**:
  1. Talk to a competitor model? **Ambiguous.** Apache-2.0 license permits the fork; Google's terms do not explicitly forbid pointing the CLI at non-Google models; but documentation/streaming protocol are Gemini-only. **Legal review recommended** for OpenAI/Anthropic-on-Vertex routing through Gemini CLI in commercial settings. **Vertex-Anthropic** routing inherits Anthropic's reseller restriction (above).
  2. Rebranded / white-labeled? **Allowed by Apache 2.0** with proper attribution. Google brand assets remain protected separately.
  3. Competing-services clause? Legacy text said "may not develop ML models"; current GCP terms reference AUP / Prohibited Use Policy but no explicit "competing services" clause on Vertex generation output for normal usage.
  4. Audit / logs? **Yes** — Google may log prompts when abuse tooling fires (§4.3).
  5. Personal vs commercial vs enterprise? AI Studio (free / personal) vs Vertex AI (commercial / GCP). Vertex is the only commercially supported path; AI Studio prohibits regulated workloads.

### 4. Aider

- **TOS sources** read on **2026-05-17**:
  - https://github.com/Aider-AI/aider/blob/main/LICENSE.txt → **Apache 2.0** (header confirmed).
  - https://aider.chat — no separate TOS / EULA.
- **License of the CLI itself**: **Apache 2.0**.
- **Key clauses**: standard Apache-2.0 grant. No vendor lock-in, no competing-products clause, no rebranding restriction beyond NOTICE-preservation.
- **Verdict**:
  1. Talk to a competitor model? **Allowed** — Aider is explicitly multi-provider via LiteLLM; that's its design.
  2. Rebranded / white-labeled? **Allowed** under Apache 2.0.
  3. Competing-services clause? **None on the CLI.** Backend choice imports the backend vendor's clauses.
  4. Audit / logs? None imposed by Aider.
  5. Tier distinction? None — same binary.
- **Risk transfer**: when Aider is wired to Anthropic, the Anthropic Commercial Terms still apply to *that backend session*. Aider cannot be used to build a competing model, not because Aider says so, but because Anthropic's terms say so on the API side.

### 5. opencode (sst)

- **TOS sources** read on **2026-05-17**:
  - https://github.com/sst/opencode/blob/dev/LICENSE → **MIT**.
- **License**: **MIT** (most permissive). No restrictions beyond copyright/license-notice preservation.
- **Verdict**: identical to Aider. **Allowed** to be wired to any backend, rebranded, embedded, redistributed. Backend-vendor terms apply independently.

### 6. Continue.dev

- **TOS sources** read on **2026-05-17**:
  - https://github.com/continuedev/continue/blob/main/LICENSE → **Apache 2.0**.
  - https://docs.continue.dev/customize/terms → 404 / page not found on 2026-05-17 (no commercial-specific TOS published at that URL).
- **License**: **Apache 2.0**.
- **Verdict**: identical to Aider — permissive, multi-backend by design. Continue.dev Hub (their hosted service for shared assistants) has separate ToS not covered here; the **self-hosted Apache-2.0 CLI/extension** is unrestricted on the client side.

### 7. Cline

- **TOS sources** read on **2026-05-17**:
  - https://github.com/cline/cline/blob/main/LICENSE → **Apache 2.0** ("Copyright Cline Bot Inc.").
- **License**: **Apache 2.0**.
- **Verdict**: identical to Aider / Continue. Permissive. Backend terms apply independently.

---

## Final compatibility matrix

Each cell is the legal status of **wiring this CLI to this backend** in a commercial corporate deployment, as of **2026-05-17**.

Legend:
- **allowed** — explicitly supported by the CLI vendor *and* compatible with the backend vendor's terms.
- **forbidden** — a defensible reading of a vendor's terms makes this wiring a breach. Launcher MUST refuse.
- **ambiguous** — terms do not clearly address this configuration; **legal review required**.
- **requires-enterprise-license** — allowed only under a negotiated commercial / enterprise agreement.

| CLI \ Backend                         | Anthropic API | Bedrock-Anthropic | Vertex-Anthropic | OpenAI / Azure-OpenAI | Vertex-Gemini | Vertex-non-Anthropic-non-Google | LiteLLM Anthropic-only | LiteLLM mixed | Self-hosted OSS (Llama, Mistral) |
|---|---|---|---|---|---|---|---|---|---|
| **Claude Code**    | allowed | allowed | allowed | **forbidden** | **forbidden** | **forbidden** | allowed | **ambiguous** | **forbidden** |
| **Codex CLI**      | allowed (upstream-merged) | allowed | allowed | allowed | allowed | allowed | allowed | allowed | allowed |
| **Gemini CLI**     | **ambiguous** (protocol mismatch + Anthropic reseller policy) | **ambiguous** | **ambiguous** | **ambiguous** | allowed | **ambiguous** | **ambiguous** | **ambiguous** | **ambiguous** |
| **Aider**          | allowed | allowed | allowed | allowed | allowed | allowed | allowed | allowed | allowed |
| **opencode**       | allowed | allowed | allowed | allowed | allowed | allowed | allowed | allowed | allowed |
| **Continue.dev**   | allowed | allowed | allowed | allowed | allowed | allowed | allowed | allowed | allowed |
| **Cline**          | allowed | allowed | allowed | allowed | allowed | allowed | allowed | allowed | allowed |

### Citations for "forbidden" and "ambiguous" cells

- **Claude Code → OpenAI / Azure-OpenAI** — *forbidden.*
  Anthropic Commercial Terms §D.4: *"Customer may not […] access the Services to build a competing product or service, including to train competing AI models or resell the Services except as expressly approved by Anthropic"*.
  Source: https://www.anthropic.com/legal/commercial-terms.
  Reinforced by Aug 2025 OpenAI-access revocation incident citing this exact clause.

- **Claude Code → Vertex-Gemini, Vertex-non-Anthropic-non-Google, Self-hosted OSS** — *forbidden.*
  Same Commercial Terms §D.4. Officially supported backends (`code.claude.com/docs/en/third-party-integrations`, 2026-05-17) are exclusively Anthropic-hosted (Console / Bedrock-Anthropic / Vertex-Anthropic / Foundry-Anthropic / Claude Platform on AWS). Non-Anthropic backends fall under "competing model providers" — the canonical breach pattern.

- **Claude Code → LiteLLM mixed** — *ambiguous.*
  A LiteLLM gateway routing only to Anthropic-hosted models is functionally identical to `ANTHROPIC_BASE_URL` and is allowed. A gateway that mixes backends and silently fails over to OpenAI/Gemini on rate limits enters §D.4 territory the moment a non-Anthropic completion is returned. Legal review required; launcher should require explicit declaration that the gateway is Anthropic-only.

- **Gemini CLI → any non-Gemini backend** — *ambiguous.*
  No explicit forbidding clause in current GCP terms. Documentation (`code.claude.com`-equivalent for Gemini: github.com/google-gemini/gemini-cli docs) describes Gemini models only. Streaming protocol incompatibility documented in gemini-cli issue #25579 — workarounds exist but are not officially supported. For Vertex-Anthropic specifically, Anthropic's reseller policy applies (Vertex partner-models doc, 2026-05-17). Legal review recommended for any production commercial wiring.

---

## Operational rules for the launcher

The launcher MUST:

1. Read `scripts/legal-matrix.json` at generation time.
2. For any user-selected (CLI, backend) pair:
   - If status is `forbidden` → refuse to generate and emit the citation.
   - If status is `ambiguous` → block generation by default; allow only with an explicit `--legal-reviewed=YYYY-MM-DD --legal-reviewer="Name <email>"` flag that gets recorded in the audit log.
   - If status is `allowed` → proceed.
3. Stamp every generated launcher bundle with the `last_read_date` of the legal matrix.
4. Refuse to generate if `last_read_date` is older than 180 days.

---

## Footnote — traceability

- **Last read of all TOS URLs cited in this document: 2026-05-17.**
- TOS change frequently. **Re-verify every 6 months** at minimum, or before any net-new corporate deployment.
- For URLs that returned 403 on direct WebFetch (`openai.com/policies/*`), the clause text was cross-checked against multiple public secondary sources (TermsFeed, MindStudio, LinkedIn analyses, all dated 2025-2026). A primary-source legal review is recommended before relying on these readings for contract negotiation.
- This document does NOT constitute legal advice. Each corporate deployment must obtain its own legal sign-off.
