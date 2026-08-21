---
name: evaluate-profile
description: >
  Turn a fresh cairn capture (footprints/<distro>/footprint-<app>.json plus
  profiles/<app>/<distro>-raw.yml) into this library's full artifact set:
  reviewed per-distro access profiles, the dev/ops doc pair, and a public
  Ansible role evaluation. Use when asked to review, tighten, or evaluate a
  captured application footprint into declarative access profiles.
---

# Evaluate a capture into the library artifact set

Positioning: `app-guide` (in the ansible-declarative-access collection) is
the EL-only in-collection guide author; `footprint-runbook` (user-level) is
the generic 13-section runbook generator. **This skill authors this repo's
artifacts** — multi-distro profiles plus the dev/ops doc pair — and owns
the review ruleset in `references/review-rules.md`. Cross-reference the
others; never duplicate their content.

## Inputs — refuse and name what's missing otherwise

1. The app's row in `matrix.yml` (packages, service names, N/A cells).
2. `footprints/<distro>/footprint-<app>.json` for every non-N/A distro.
3. `profiles/<app>/<distro>-raw.yml` for every non-N/A distro.
4. The app class: `webserver | app-server | proxy | database | cache`.
5. The two gold exemplars as format reference: `profiles/nginx/` +
   `docs/apps/nginx/` (webserver) and `profiles/postgresql/` +
   `docs/apps/postgresql/` (database).

## Evidence gates (non-negotiable)

- Never describe "what the install creates" from memory — read the JSON.
- Every profile line must trace to footprint evidence, or carry a
  `# REVIEW-ADD:` comment naming why the reviewer added it (e.g. `/var/log`
  is excluded from footprints by default).
- Stop if `footprint_type != install_time` or fidelity is degraded.
- The `# VERIFIED:` header line is written only after
  `scripts/verify-profile.sh <app> <distro>` passed for that pair. Reviewed
  but unverified profiles say `# VERIFIED: pending`.

## Process, per app

1. **Read the evidence** — for each distro: `summary`, `risks[]`,
   `principals`, `services.systemd_units[]` (+ `quadlets`), `group_access`,
   `privilege.sudoers_files`, `filesystem.added_by_category` category
   counts. Note distro divergences immediately (unit names, accounts,
   paths) against `references/distro-map.md`.
2. **Review each raw profile** into `<distro>-access.yml` using
   `references/review-rules.md`. Keep the raw file byte-identical. Every
   delta carries exactly one `REVIEW-DROP/KEEP/ADD` comment
   (`docs/conventions.md` §4). Header block: PROVENANCE (footprint file +
   capture date + cairn source), ACCESS MODEL one-liner, APPLY + revoke
   commands, `# REVIEWED:` and `# VERIFIED:` lines.
3. **Verify** — run `scripts/verify-profile.sh <app> <distro>` for every
   reviewed profile; fix and re-run until green; record the line.
4. **Write the doc pair** — `docs/apps/<app>/dev.md` + `ops.md` per
   `references/doc-templates.md`, honoring `docs/conventions.md`
   (grants quoted verbatim; concepts linked, not restated; explicit N/A
   cells; mandatory honesty sections).
5. **Role evaluation** — `docs/role-evals/<app>.md` per
   `references/role-eval-rubric.md`; candidates researched by web search at
   evaluation time (record dates), seeded from the known Galaxy options
   (geerlingguy.*, linux-system-roles, vendor-official roles).
6. **Index** — flip the app's row in `docs/index.md`'s status table.
