# Ansible role evaluation: HAProxy (AlmaLinux 9/10, Amazon Linux 2023, Ubuntu 24.04/26.04)

## 1. Method

The reviewed HAProxy profiles (`profiles/haproxy/*-access.yml`) and the
[dev](../apps/haproxy/dev.md)/[ops](../apps/haproxy/ops.md) docs are the
requirement rubric; a public Ansible role is scored on how much of it the role
delivers, reading the role's **actual tasks/templates on GitHub**, not its
README. What no role delivers becomes the spec for the org overlay. All findings
web-checked **2026-08-09**; GitHub activity decays, so re-verify before adopting.

## 2. Candidates

| Role | Backing | Status (checked 2026-08-09) |
|---|---|---|
| [geerlingguy.haproxy](https://github.com/geerlingguy/ansible-role-haproxy) | Community, very widely deployed (Jeff Geerling) | Active. No GitHub *Releases* published (versioned on Galaxy); 74 commits; **CI molecule matrix = `rockylinux9` + `ubuntu2404`** — our two primary families. `min_ansible 2.10`. |
| [robertdebock.haproxy](https://github.com/robertdebock/ansible-role-haproxy) | Community (24★) | Active, not archived; 501 commits; molecule matrix EL (all) + Ubuntu jammy/**noble** + Debian + Fedora 42. `min_ansible 2.12`. |
| [haproxytech/dataplaneapi](https://github.com/haproxytech/dataplaneapi) | **Vendor-official (HAProxy Technologies)** | Active — **but not an Ansible role.** It is a Go REST sidecar that rewrites `haproxy.cfg` at runtime via API (see §4). Orthogonal to config-file management; eliminated as a *role* candidate. |
| Oefenweb.haproxy, socketwench.haproxy (fork), emmetog.haproxy (fork), rolehippie.haproxy | Community | Niche / Ubuntu-only / forks of geerlingguy — not evaluated in depth. No vendor-official *install* role exists for the classic service. |

There is **no vendor-official Ansible role** for installing/configuring the
classic HAProxy service — the vendor's automation story is the Data Plane API
(§4). The field is community roles.

## 3. Rubric scoring (requirements from our profile + docs)

| # | Requirement (from the reviewed profile / docs) | geerlingguy | robertdebock |
|---|---|---|---|
| R1 | All five cells correct — EL family (alma9/10, AL2023): `/etc/haproxy` + `conf.d` (loaded via `$CFGDIR`); Ubuntu (24.04/26.04): single `haproxy.cfg`, no `conf.d`; `haproxy` user/group; runs as root. Our 2026-08-23 captures show packaging is byte-identical within each family, so correct two-family task logic reaches all five cells | ⚠️ installs on both families (AL2023 rides the RedHat path — untested upstream), but templates one whole `haproxy.cfg` — ignores EL's `conf.d` model | ⚠️ same whole-file model; explicitly creates the `haproxy` user/group |
| R2 | Install + configure via native package/config | ✅ pkg install + validated `haproxy -f %s -c -q` before restart | ✅ pkg install + validated `haproxy -c -f %s` + backup |
| R3 | Drop-in discipline **or** deterministic whole-file template (FIM: no `ansible_managed` timestamp) | ⚠️ whole-file; **no** `ansible_managed` header at all (deterministic, but also unmarked) | ✅ whole-file with a timestamp-free "Managed by Ansible" comment — deterministic (see §4) |
| R4 | systemd hardening drop-in (`NoNewPrivileges`/`ProtectSystem` — matters: haproxy runs as **root**, our `risks[]`) | ❌ | ❌ |
| R5 | Env/flag file mgmt (`/etc/default/haproxy` `$EXTRAOPTS` / `/etc/sysconfig/haproxy` `$OPTIONS`) | ⚠️ edits `/etc/default/haproxy` only to enable on Debian | ❌ |
| R6 | **Access model** — scoped sudoers, pam_group decision, config ACL | ❌ | ❌ |
| R7 | Verification / idempotence (molecule, our five cells) | ⚠️ molecule `rockylinux9` + `ubuntu2404` — 2 of our 5 cells (alma9-equivalent + ubuntu 24.04); alma10, ubuntu 26.04 and AL2023 untested upstream | ⚠️ broader molecule (EL/noble/Debian/Fedora) — reaches alma9/10 + 24.04, still no ubuntu 26.04 or AL2023 |
| R8 | TLS wiring (and our PEM-in-platform-key-dir doctrine) | ❌ template has HTTP `bind` only, no `ssl`/`crt` | ⚠️ frontends/listens support `ssl crt`, but no cipher/`ssl-default-*` policy and no key-placement opinion |
| R9 | logrotate policy management | ❌ (relies on package fragment) | ❌ |
| R10 | Maintenance & platform assurance for OUR versions (alma9/10, AL2023, Ubuntu 24.04/26.04) | ⚠️ active, EL9 (rocky9) + 24.04 in CI, but **alma10, ubuntu 26.04 and AL2023 unassured**; Galaxy `meta` platforms stale (lists Ubuntu precise/trusty/xenial) | ⚠️ active, noble + EL "all" + Fedora 42 assures 3 of 5; **ubuntu 26.04 and AL2023 unassured**; more current `min_ansible` |

R4, R6, R9 fail for **both** — the standing gap between public roles ("make the
software run") and our runbooks ("make it operable and least-privilege").

## 4. Nuances found

**Whole-file templating vs our EL `conf.d` model — and it's mostly fine.** Both
roles render the entire `haproxy.cfg` rather than dropping fragments into
`conf.d`. Our dev doc tells *human* admins to use `conf.d` on EL and edit
`haproxy.cfg` directly on Ubuntu. These don't actually conflict: under config
management the calculus inverts, exactly as the chrony/timesync case found —
Ansible owns the file, the FIM baseline accepts the *rendered* version, and any
drift is a tamper signal (a **stronger** integrity property than hand-edited
drop-ins). Two caveats: (1) keep the render deterministic — robertdebock's
timestamp-free comment is correct; geerlingguy ships no header at all, which is
deterministic but loses the "managed by Ansible" marker; (2) whole-file
templating means a role **re-run overwrites the team's ACL-based hand edits** to
`haproxy.cfg`, so post-lockdown config changes must flow through the role in a
change window, not through the granted ACL (§6a).

**The vendor path is the Data Plane API, and it fights lockdown.** HAProxy
Technologies' official automation is `dataplaneapi` — a root sidecar that
rewrites `haproxy.cfg` (and a `.cfg`-fragment structured config dir) via REST at
runtime. That is incompatible with both our FIM/whole-file-determinism posture
and a locked-down filesystem (it needs write access to the config tree and a
privileged control socket). It is a *runtime reconfiguration* tool, not an
install role; if a team wants it, it is a reviewed, root-owned service of its
own, not part of the restricted profile.

## 5. Verdict: adopt + wrap (do NOT build from scratch, do NOT adopt bare)

1. **Adopt `geerlingguy.haproxy` as the config engine.** Its molecule CI targets
   our exact two primary families (`rockylinux9` ≈ alma9, `ubuntu2404`), it is
   the most widely deployed option, and its scope is deliberately narrow (install
   + validated whole-file config + service) — which is precisely the half we
   want a public role to own. Action items before rollout: **pin the version**;
   add molecule targets for **alma10, ubuntu 26.04 and AL2023** (no upstream
   role tests any of them); and supply a TLS frontend yourself (R8 gap — its
   template is HTTP-only). If you need
   Ubuntu-noble-first metadata plus built-in `ssl crt` frontends, **robertdebock.haproxy**
   is the fallback config engine (more current `min_ansible`, broader matrix) at
   the cost of a less battle-tested user base.
2. **Build a thin org overlay** carrying exactly the rows every public role fails:
   - **R4** systemd hardening drop-in — `/etc/systemd/system/haproxy.service.d/hardening.conf`
     (`NoNewPrivileges`, `ProtectSystem=strict`, capability bounding). This is
     the concrete mitigation for our accepted `service_runs_as_root` risk.
   - **R5** env-file templates (`/etc/sysconfig/haproxy`, `/etc/default/haproxy`).
   - **R6** the **access model** — and this is already done: it *is* the reviewed
     profile in this repo (scoped sudoers + `/etc/haproxy` config ACL + the
     deliberate pam_group/content/log drops). No role should own it.
   - **R9** a logrotate/ rsyslog-to-a-dedicated-**dir** policy so file log reads
     become grantable and rotation-safe (see [ops §10](../apps/haproxy/ops.md)).
   - **R8/TLS** enforce the PEM-in-platform-key-dir doctrine
     ([dev §4](../apps/haproxy/dev.md)) — the `crt` path points at
     `/etc/pki/tls/private` (EL) / `/etc/ssl/private` (Ubuntu), never
     `/etc/haproxy/certs`.
3. **Generalize.** R4/R5/R6/R9 fail for *every* public role for *every* service —
   one reusable overlay role parameterized per service covers it fleet-wide; the
   per-app profile in this repo is its access-model input.

## 6. Implementing least privilege with this role

From "we picked geerlingguy.haproxy" to "the team is locked down and knows how
to operate", in four steps.

### 6a. Where the role runs in the lifecycle

The role runs during the **setup window** (executor in `<hostname>-app_full`) or
via platform automation — always **before capture**, so its outputs land in the
footprint like a manual install and are then reviewed into the profile. See
[lifecycle](../concepts/lifecycle.md).

| Role output | Lands as | Profile key |
|---|---|---|
| `haproxy` package + service | installed unit, `haproxy` user/group | `declarative_access_services: [haproxy]` (read-only units) |
| Templated `/etc/haproxy/haproxy.cfg` (whole file) | config tree under `/etc/haproxy` | `declarative_access_folders_modify: [/etc/haproxy]` (config write ACL) |
| `restart haproxy` handler | the reload/restart verb that matters | granted by the service key — prefer the seamless `reload` (see [dev §2](../apps/haproxy/dev.md)) |
| (nothing) — role writes no sudoers/pam/ACLs | — | the access model stays entirely ours; **no conflict to disable** |

**Wrap notes.**
- **Pin the role version.** A version bump can change the rendered `haproxy.cfg`
  or touched paths → the footprint changes → re-capture and re-review.
- **Re-running the role post-lockdown is a platform act.** Because it templates
  the whole `haproxy.cfg`, a re-run (a) clobbers any team ACL hand-edits — so
  route steady-state config changes through the role in a change window, not the
  granted ACL — and (b) replaces the file, shedding its ACL, so **re-run
  playbook 5 afterwards** (idempotent) to restore the config grant.

### 6b. Configuring the deployment for least privilege

The vars that keep the install least-priv-compatible, from the role's own
`defaults/main.yml` + `templates/haproxy.cfg.j2` (read 2026-08-09):

- **Config stays root-owned — nothing to disable.** The role writes
  `/etc/haproxy/haproxy.cfg` as root with no ownership override and never
  chowns config to the service account or writes its own sudoers (confirmed in
  `tasks/main.yml`). The team's write path is the reviewed profile's ACL, not
  ownership.
- **Run as the packaged system account.** Keep the defaults
  `haproxy_user: haproxy` / `haproxy_group: haproxy` — they render the
  `user`/`group` privilege-drop lines in `global` (the worker drop
  [dev §2](../apps/haproxy/dev.md) describes). Never point them at a login
  user.
- **Keep the chroot and admin socket inside the root-owned state dir.**
  Defaults `haproxy_chroot: /var/lib/haproxy` and
  `haproxy_socket: /var/lib/haproxy/stats` match the packaged `root:root`
  state dir the profile deliberately does **not** grant ([ops §2](../apps/haproxy/ops.md)).
  Do not relocate the socket under `/etc/haproxy` — that would put a live
  admin-level control socket inside the team's config write ACL.
- **Port posture: nothing to configure.** Frontends bind <1024 (default
  `haproxy_frontend_port: 80`) because the master runs as root by design —
  our accepted `risks[]` row ([ops §11](../apps/haproxy/ops.md)); no
  capability vars exist and none are needed.
- **Logging: leave syslog routing alone** so the profile's per-unit
  `journalctl` grant stays the health path. Routing traffic logs to a
  grantable dedicated log **dir** ([ops §10](../apps/haproxy/ops.md)) is
  rsyslog/logrotate work — **not expressible with this role** (R9 ❌; the org
  overlay owns it).
- **TLS: supply the frontend yourself, key in the platform dir.** The role's
  template is HTTP-only (R8 ❌); when the overlay adds the `bind ... ssl crt`
  frontend, the `crt` path points at `/etc/pki/tls/private` (EL) /
  `/etc/ssl/private` (Ubuntu), never `/etc/haproxy/certs`, keeping the PEM's
  private half out of the team's config ACL ([dev §4](../apps/haproxy/dev.md)).
- **systemd hardening drop-in** (`NoNewPrivileges`, `ProtectSystem`, capability
  bounding — the mitigation for the accepted root-run risk): **not expressible
  with this role** (R4 ❌; org overlay, §5.2).

### 6c. Applying the access profile

Once the role has deployed and capture/review is done, lockdown is playbook 5
(`5_apply_access_profile.yml`) with this app's reviewed profile — then the
verify pass and the flip out of app-full, exactly as the
[ops runbook](../apps/haproxy/ops.md) steps them (§4–§6):

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/haproxy/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
```

All five distro cells ship a reviewed profile
(`profiles/haproxy/{almalinux-9,almalinux-10,amazonlinux-2023,ubuntu-24.04,ubuntu-26.04}-access.yml`).

### 6d. Who does what after lockdown

**Application team** — your admin surface is
[dev.md, "your life after lockdown"](../apps/haproxy/dev.md): the granted
`systemctl` verb set (prefer the seamless master-worker `reload`), the
verbatim `journalctl -u haproxy` spellings, config edits under the
`/etc/haproxy` ACL (`conf.d` drop-ins on EL, fenced `haproxy.cfg` edits on
Ubuntu) with the no-sudo `haproxy -c` validator, and the TLS/log boundaries.

**Operations team** — your reference is the
[ops runbook](../apps/haproxy/ops.md): the footprint evidence (§1), the
raw→reviewed decision record (§2), apply/verify/flip/revoke (§4–§7), drift
after patching (§8), TLS key custody (§9), log-dir grants (§10), and the
`risks[]` triage (§11) — including the org-overlay hardening drop-in that
reduces the accepted root-run risk.

## 7. If nothing fits

Not applicable — a config engine is adopted. The overlay described in §5.2
(`org.haproxy_hardening`, or a generic `org.service_baseline` pattern) carries
R4/R5/R9 and enforces the TLS key-placement rule; R6 is already delivered by this
repo's reviewed profile. Scope: alma9/10 + AL2023 + Ubuntu 24.04/26.04;
molecule expectations matching our matrix (add alma10, ubuntu 26.04 and
AL2023, which no upstream role tests). **Not scheduled** — it is the same
fleet-wide overlay every service in this library needs, not a haproxy-specific
build.

## 8. Sources

- https://github.com/geerlingguy/ansible-role-haproxy — `tasks/main.yml`,
  `templates/haproxy.cfg.j2`, `defaults/main.yml`, `meta/main.yml`,
  `.github/workflows/ci.yml` (matrix `rockylinux9`, `ubuntu2404`) — read 2026-08-09
- https://github.com/robertdebock/ansible-role-haproxy — `tasks/main.yml`,
  `templates/haproxy.cfg.j2`, `meta/main.yml` (platforms EL all / Ubuntu
  jammy+noble / Debian / Fedora 42; `min_ansible 2.12`) — read 2026-08-09
- https://github.com/haproxytech/dataplaneapi — vendor Data Plane API (not an
  Ansible role) — read 2026-08-09
- Requirement source: `profiles/haproxy/*-access.yml` (all five cells),
  `docs/apps/haproxy/{dev,ops}.md`
- Five-cell packaging identity (family-identical raws; AL2023/ubuntu-26.04
  parity): `footprints/<distro>/footprint-haproxy.json`, captured 2026-08-23
  on KVM golden images (treadmark 0.11.0)
