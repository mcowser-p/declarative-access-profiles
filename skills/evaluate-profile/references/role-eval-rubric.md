# Role evaluation rubric

Method: the app's reviewed profile + dev/ops docs are the requirement
rubric; a public Ansible role is scored on how much of it the role
delivers. What no role delivers becomes the spec for the org overlay.
Modeled on the chrony worked example in treadmark's runbook corpus.

## Sections (docs/role-evals/<app>.md)

1. **Method** — two sentences + the evaluation date (web-search findings
   decay; date everything).
2. **Candidates** — table: role (Galaxy name + repo link), backing
   (vendor-official / Red Hat linux-system-roles / community + stars),
   status (last release/commit; archived ⇒ eliminated on sight). Seed
   candidates: `geerlingguy.*`, `linux-system-roles.*`, vendor roles
   (`nginxinc.nginx`, `community.mysql`-adjacent), plus whatever search
   surfaces. Verify activity via the repo, not Galaxy's cache.
3. **Rubric scoring** — fixed rows, ✅/⚠️/❌ with a one-line evidence note
   (read the role's templates/tasks — score from code, not README):
   - R1 covers both our distro families (paths/units/accounts correct)
   - R2 installs + configures via native package/config mechanisms
   - R3 drop-in discipline (or whole-file templating — note the FIM
     consequence: rendered file must be deterministic, `ansible_managed`
     timestamp-free)
   - R4 systemd hardening drop-ins
   - R5 env/secret file management
   - R6 **access model** (sudoers scoping, pam_group, ACLs) — the standing
     all-roles-fail row; that gap is this library's job
   - R7 verification/idempotence quality (molecule? which platforms?)
   - R8 TLS wiring
   - R9 logrotate policy management
   - R10 maintenance & platform assurance for OUR versions (EL9/10,
     Ubuntu 24.04)
4. **Nuances found** — free slot (the chrony eval's
   whole-file-vs-drop-in analysis is the exemplar).
5. **Verdict** — adopt / adopt+wrap / build, with reasoning bullets.
6. **Implementing least privilege with this role** — the section that
   makes these evals different. Four fixed subsections, so a reader can go
   from "we picked this role" to "the team is locked down and knows how to
   operate":
   - **6a. Where the role runs in the lifecycle** — during the **setup
     window** (executor in app-full) or via platform automation — always
     **before capture**, so its outputs land in the footprint like a
     manual install. Mapping table: role outputs → profile keys (units →
     `_services`/`_timers`; templated config tree → `folders_modify` or
     the group model; handlers → the reload verb mattering). Wrap notes:
     **pin the role version** (a version bump changes the footprint →
     re-capture, re-review); re-running the role post-lockdown is a
     platform act — if it replaces ACL'd files, re-run playbook 5 after
     (idempotent).
   - **6b. Configuring the deployment for least privilege** — the role
     vars and app config that keep the install least-priv-compatible,
     scored from the role's own code: keep config root-owned (disable any
     role behavior that chowns config to the service account or writes
     its own sudoers); run the service as its packaged system user, never
     a login user; port/capability posture (e.g. ambient
     `CAP_NET_BIND_SERVICE` vs >1024); log to the packaged log dir or
     journald so the profile's log grants hold; secrets via R5's
     mechanism, never world-readable. Name the exact vars with values
     where the role provides them; say "not expressible with this role"
     where it doesn't.
   - **6c. Applying the access profile** — the concrete lockdown step
     once the role has deployed and capture/review is done: the
     `5_apply_access_profile.yml` invocation with this app's reviewed
     profile (`-e @profiles/<app>/<distro>-access.yml
     -e group_name=<hostname>-app_restricted`), the verify pass, and the
     flip out of app-full. Two sentences + the command — the full
     runbook lives in ops.md; link, don't duplicate.
   - **6d. Who does what after lockdown** — one paragraph each with
     links: the application team's admin surface is dev.md ("your life
     after lockdown": granted systemctl verbs, journalctl, config edit
     paths); the operations team's reference is ops.md (evidence,
     raw→reviewed decisions, apply/verify/revoke, risk triage).
7. **If nothing fits** — spec stub for an org install role (scope, distro
   matrix, molecule expectations), two paragraphs max, marked
   "not scheduled".
8. **Sources** — URLs + dates for every claim.
