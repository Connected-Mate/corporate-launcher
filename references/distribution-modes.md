# Distribution modes

After the launcher is generated locally, the skill asks how the creator wants to ship it to their team. Each mode produces a different artifact under `dist/`.

---

## Table of contents

- [Quick comparison](#quick-comparison)
- [The interview question](#the-interview-question)
- [Mode 1 — Public GitHub repo](#mode-1--public-github-repo)
- [Mode 2 — Private GitHub / GitLab repo](#mode-2--private-github--gitlab-repo)
- [Mode 3 — Tarball + internal artifact registry](#mode-3--tarball--internal-artifact-registry)
- [Mode 4 — One-liner install URL](#mode-4--one-liner-install-url)
- [Mode 5 — No distribution](#mode-5--no-distribution)
- [What about update channels?](#what-about-update-channels)
- [Distribution mode × Skills bundle interactions](#distribution-mode--skills-bundle-interactions)
- [Choosing a mode](#choosing-a-mode)

---

## Quick comparison

| Mode | Setup time | Security audit | Update path | Best for |
|---|---|---|---|---|
| Mode 1 — Public Git | 5 min | low (anyone sees it) | git pull | OSS evangelism |
| Mode 2 — Private Git | 10 min | medium | git pull | most enterprise |
| Mode 3 — Tarball + registry | 30 min | high (signed) | re-pub | air-gapped, regulated |
| Mode 4 — One-liner URL | 15 min | medium-high (with checksum) | re-run | quick rollout |
| Mode 5 — Local only | 0 min | n/a | n/a | iteration |

---

## The interview question

```
How do you want to ship this to your team?

  [1] Public GitHub repo
  [2] Private GitHub / GitLab repo
  [3] Tarball + internal artifact registry (Nexus, Artifactory)
  [4] One-liner install URL (host install.sh on your intranet)
  [5] No distribution — local only for now
```

Save as:

| Var | Type | Example |
|---|---|---|
| `DIST_MODE` | enum | `public-git` / `private-git` / `tarball` / `oneliner` / `none` |
| `DIST_REPO_HOST` | enum | `github` / `gitlab` / `bitbucket` / `internal-gitea` |
| `DIST_REPO_URL` | URL | `https://github.acme.internal/ai-platform/copilot.git` |
| `DIST_REPO_VISIBILITY` | enum | `public` / `internal` / `private` |
| `DIST_REGISTRY_URL` | URL | `https://nexus.acme.internal/repository/raw/` |
| `DIST_ONELINER_HOST` | URL | `https://copilot.acme.internal/install` |
| `DIST_SIGN_RELEASE` | bool | `true` / `false` |
| `DIST_GPG_KEY_ID` | string | `0xABCD1234` (if signing) |

---

## Mode 1 — Public GitHub repo

The simplest mode. Best for open-source evangelism, OSS projects, or a launcher that's already designed to be public (only branding + skills, no leaked endpoints).

The skill scaffolds a clean repo under `dist/repo/` with:
- the launcher tree
- `.gitignore`
- `LICENSE`
- a generated `README.md` adapted from `templates/dist/dist-readme/public.md.tpl`
- a `CHANGELOG.md` initialized at v0.1.0

Then it runs:

```bash
gh repo create "$DIST_REPO_URL" --public --source=dist/repo --push
```

Final output: a URL the creator shares with the world.

⚠️ **Warning**: the skill refuses to ship a public repo if `${CC_PRIMARY_URL}` contains an internal hostname (`.internal`, `.local`, anything that resolves to RFC1918). The creator must explicitly override with `DIST_PUBLIC_FORCE=yes`.

Trade-offs:

**PROS**
- ✅ Fastest setup (5 min, no auth on the consumer side).
- ✅ Free hosting, free CI, free issue tracker.
- ✅ Drive-by contributors and OSS goodwill.

**CONS**
- ❌ Anything you push is world-readable — secrets, internal hostnames, employee names leak forever.
- ❌ No access control; you can't reach a specific subset of colleagues.
- ❌ Public commit history reveals project velocity, gaps, and stack choices to competitors.

---

## Mode 2 — Private GitHub / GitLab repo

Most common production setup. The launcher tree goes into a private repo, colleagues clone it (with their existing SSO / SSH key), and run the bundled `install.sh`.

The skill scaffolds the same tree as Mode 1, then runs:

```bash
gh repo create "$DIST_REPO_URL" --private --source=dist/repo --push
# or for GitLab:
glab repo create --private "$DIST_REPO_URL"
```

If the corporate git host isn't reachable from the skill's session (offline / VPN required), the skill prints the manual steps:

```
1. Create the repo manually:  https://gitlab.acme.internal/projects/new
2. Push from this machine:
     cd dist/repo
     git init -b main
     git remote add origin git@gitlab.acme.internal:platform/copilot.git
     git add . && git commit -m "Initial"
     git push -u origin main
```

Final output: the repo URL + a one-line install command for colleagues:

```bash
git clone https://gitlab.acme.internal/platform/copilot.git && \
    cd copilot && ./install.sh
```

Trade-offs:

**PROS**
- ✅ Leverages existing corporate SSO / SSH / VPN — no new auth to design.
- ✅ Clean `git pull` update path; colleagues already know the workflow.
- ✅ Built-in audit trail (commits, MRs, code review) for compliance.

**CONS**
- ❌ Requires colleagues to have git access to the host (offline laptops are blocked).
- ❌ No signed releases by default; trust is implicit in the host.
- ❌ Updates are pull-based — you can't push a security fix, you can only hope users `git pull`.

---

## Mode 3 — Tarball + internal artifact registry

For air-gapped environments or shops that already manage versioned binaries via Nexus / Artifactory / S3.

The skill produces:
- `dist/<slug>-<version>.tar.gz`
- `dist/SHA256SUMS`
- `dist/SHA256SUMS.asc` if `DIST_SIGN_RELEASE=true` and a GPG key is configured

Plus an `upload.sh` helper that points to the configured registry:

```bash
curl -u "$NEXUS_USER:$NEXUS_PASS" \
    --upload-file "dist/<slug>-<version>.tar.gz" \
    "https://nexus.acme.internal/repository/raw/copilot/"
```

Colleagues fetch and verify:

```bash
curl -O https://nexus.acme.internal/repository/raw/copilot/<slug>-<version>.tar.gz
curl -O https://nexus.acme.internal/repository/raw/copilot/SHA256SUMS
sha256sum -c SHA256SUMS
tar xzf <slug>-<version>.tar.gz
cd <slug>-<version> && ./install.sh
```

Trade-offs:

**PROS**
- ✅ Works behind air-gap or zero-egress networks.
- ✅ Versioned, signable, auditable — passes the strictest security reviews.
- ✅ Plugs into existing artifact retention, SBOM, and CVE-scan pipelines.

**CONS**
- ❌ No update path without re-publishing a full tarball.
- ❌ Heaviest setup (registry creds, GPG key, signing pipeline).
- ❌ Colleagues must learn the verify-and-extract flow; higher friction than `git clone`.

---

## Mode 4 — One-liner install URL

The "convenience" mode. The creator hosts `install.sh` at a known URL on the corporate intranet, and shares a single command with their team:

```bash
curl -fsSL https://copilot.acme.internal/install | bash
```

The skill generates:
- `dist/install.sh` — the install script, parameterized for the chosen distribution backend
- `dist/install.sh.sha256` — a checksum companion file

It does **not** host the file — the creator drops it on their intranet (S3, NGINX, GitHub Pages, etc.). The skill prints the exact `aws s3 cp` / `scp` / `gh release upload` command to publish it.

⚠️ **Security note**: every `curl ... | bash` is a trust statement. The skill enforces:

1. A `--verify-checksum` mode that downloads `install.sh.sha256` first and validates.
2. The host URL must be HTTPS. Plain HTTP → refuse.
3. If `DIST_SIGN_RELEASE=true`, the install script verifies a GPG signature before executing the bundled binaries.

The colleague-facing command:

```bash
# Standard (trust-the-host model):
curl -fsSL https://copilot.acme.internal/install | bash

# Defensive (recommended, with checksum):
curl -fsSL https://copilot.acme.internal/install.sh -o /tmp/install.sh && \
    curl -fsSL https://copilot.acme.internal/install.sh.sha256 -o /tmp/install.sh.sha256 && \
    cd /tmp && sha256sum -c install.sh.sha256 && bash install.sh
```

Trade-offs:

**PROS**
- ✅ One-line install — lowest friction for the consumer.
- ✅ Re-run pulls the latest; effectively free updates.
- ✅ Works for colleagues on any OS without git or registry tooling.

**CONS**
- ❌ `curl | bash` is a trust statement; security teams often block it on principle.
- ❌ You own the hosting (S3, NGINX, GitHub Pages) — uptime is on you.
- ❌ No version pinning by default; "what did I install yesterday?" is hard to answer.

---

## Mode 5 — No distribution

The skill skips the dist step entirely. The launcher exists only on the creator's machine. Use this when:
- The creator is still iterating and isn't ready to ship.
- The launcher is a one-person experiment.
- A separate ops process will handle distribution (Ansible, Puppet, Jamf, Intune).

Trade-offs:

**PROS**
- ✅ Zero setup, zero hosting, zero auth.
- ✅ Fastest iteration loop — edit and re-run locally.
- ✅ No premature commitment to a distribution backend.

**CONS**
- ❌ Nobody else can use it; "works on my machine" by construction.
- ❌ No version history, no rollback, no audit.
- ❌ Trivial to lose (one `rm -rf` away).

---

## What about update channels?

The launcher's `install.sh` supports `--update` regardless of distribution mode. For git-based modes, `--update` does `git pull` and re-runs the install. For tarball/oneliner modes, `--update` re-downloads and re-checksums.

For modes where atomic rollback is critical (production fleet), the creator should pair the launcher with their existing config management (Ansible, etc.) rather than the bundled `--update`.

---

## Distribution mode × Skills bundle interactions

| Skills mode | Best distribution mode | Why |
|---|---|---|
| `none` | any | nothing to ship besides the wrapper |
| `preset` | git repo | presets are pinned by version, easy to update |
| `pick` | git repo | same as preset |
| `git` (SKILLS_GIT_URL) | git repo or tarball | colleagues' machines need git access either way |
| `local` (frozen folder) | tarball | the skills are immutable once shipped |

The skill picks a sensible default based on the combination and confirms with the creator before generating.

---

## Choosing a mode

If you don't know, pick Mode 2 (private git). It's the right answer 80% of the time.
