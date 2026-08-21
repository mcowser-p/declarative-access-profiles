# Doc templates — dev.md and ops.md section contracts

Follow the gold exemplars (`docs/apps/nginx/`, `docs/apps/postgresql/`) for
register and depth; this file is the section contract. All rules in
`docs/conventions.md` apply — especially: grants quoted verbatim, concepts
linked not restated, explicit N/A cells, honesty sections mandatory.

## dev.md — "<App> — your life after lockdown"

Open with one line: you deployed <app>, you're now in
`<hostname>-app_restricted`, this page is everything you can still do.

- **§0 First command: `sudo -l`** — sudo matches the whole command string,
  argument order included; copy from `sudo -l` output, not memory.
- **§1 Your grants at a glance** — table (What / How it's granted /
  Example), one row per grant class: systemctl verbs, journalctl variants
  (verbatim), config paths (say the mechanism: ACL vs group+setgid), content
  paths, log read, service-group at login (pam_group: next login, SSH
  sessions only, not cron). Generated from the reviewed profile.
- **§2 Administering your systemd units** — verbs per unit type (services:
  full set; timers: `.timer` suffix required, no reload; quadlets:
  start/stop/restart/status only + why); `daemon-reload` granted, global,
  needed after unit edits; reload-vs-restart guidance for THIS app.
- **§3 Editing configuration** — drop-in discipline (never the vendor main
  config; one intention per file; validate before reload — say whether the
  validator needs sudo and whether it's granted); the "why did my write
  fail" playbook: logged in before the profile applied? (pam_group is
  per-login) → `getfacl` the path.
- **§4 TLS / SSL administration** — what you can touch (TLS config +
  granted reload) vs can't (private key dirs, root-only, in NO profile);
  this app's row from the per-app nuances in `concepts/tls-ssl.md`; the
  renewal flow (expiry check needs no privileges; platform drops files —
  or you swap the keystore where that's the model; YOU run the granted
  reload/restart); ops escalations (new module install, ports <1024, key
  permissions).
- **§5 Logs and log rotation** — where logs live; granted journalctl
  spellings verbatim; file reads via the log-dir ACL; the two canonical
  facts linked from `concepts/logging.md`: default ACLs keep rotated files
  readable; the logrotate `create`-mode mask gotcha with the
  `getfacl` `#effective:` diagnostic; `/etc/logrotate.d/<app>` is outside
  your grant — retention changes are a request.
- **§6 Everything else you'll eventually need** — env files/secrets
  location and whether it's in a granted path; timers you own; the change
  window process (back into app-full → work → handover again); the
  denied-command playbook (read the denial, `sudo -l`, request template).
- **§7 Per-distro differences** — table over all three distros (package,
  unit, account, config root, drop-in dir, log dir, validator, TLS paths);
  explicit `N/A on <distro> — <reason>` cells.
- **§8 Cheat sheet** — copy-paste block: health, config change cycle, logs,
  `sudo -l`.

## ops.md — "<App> — lockdown runbook (ops)"

- **§1 Footprint summary (evidence)** — table from the JSON: counts, units
  (installed vs dependency-pulled), accounts created (uid/shell), key dirs
  with captured owner:mode; source line (footprint file, schema, date,
  cairn version). Quote `privilege.sudoers_files[]` content here if any.
- **§2 Raw → reviewed: the decisions** — one row per delta with the
  REVIEW-* tag and a WHY sentence. This is the review record.
- **§3 Access model for this app class** — name the model; the reduced
  decision table rows this app uses; the DB pam_group apply-time opt-in
  where relevant.
- **§4 Apply** — playbook 5 command with this profile; artifact checklist
  (sudoers file path, group.conf line, setfacl targets, ownership changes,
  linger); `visudo -cf` sanity.
- **§5 Verify** — allow probes / deny probes / behavioral pam_group check
  (fresh SSH login, `id`, group-writable write); stale-session false
  negative warning. Cite the `scripts/verify-profile.sh` run.
- **§6 Flip** — remove from app-full (nesting already granted restricted),
  `loginctl terminate-user`, `sss_cache -E`, confirm next login.
- **§7 Revoke / tighten later** — the three moments; cleanup exceptions
  verbatim (parent traverse ACLs remain; ownership never reverted; linger
  disable stops ALL the user's rootless services).
- **§8 Drift and patching** — what `rpm -V`/`dpkg --verify` flags
  (intentional setgid/ownership changes → accept-list entries) vs what it
  can't see (ACLs); package updates replace files and shed file ACLs →
  re-run playbook 5 (idempotent); authselect caveat.
- **§9 TLS: key ownership and rotation** — who owns key material for this
  app; the rotation runbook keeping the boundary (platform places, team
  reloads); the cert-admin opt-in profile where a team must own the cert
  dirs.
- **§10 Logs** — journalctl grants are per-unit scoping (never the
  `systemd-journal` group); the pre-flip `logrotate -f` + `getfacl` test;
  apps that ship rotation disabled or self-rotate (postgres
  `log_file_mode`).
- **§11 Known risks** — every `risks[]` entry: severity, accept-or-fix,
  owner.
