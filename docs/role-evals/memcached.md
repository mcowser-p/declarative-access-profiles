# Ansible role evaluation: memcached (AlmaLinux 9/10 + Ubuntu 24.04)

## 1. Method

The reviewed profiles and the [dev](../apps/memcached/dev.md)/[ops](../apps/memcached/ops.md)
docs are the requirement rubric; a public role is scored (R1–R10) on how much of
it the role delivers, read from the role's **code**, not its README. What no role
delivers becomes the spec for the org overlay. Evaluated **2026-08-09** (web-search
findings decay — dates are load-bearing). memcached is a trivial install (one
package, one config file, one service), so the interesting axes are R1 (does the
role get the EL-vs-Debian account/path split right?), R9 (both roles introduce an
unrotated log file), and the whole-file-config-vs-our-ACL collision (§4).

## 2. Candidates

| Role | Backing | Status (verified via repo, 2026-08-09) |
|---|---|---|
| [geerlingguy.memcached](https://github.com/geerlingguy/ansible-role-memcached) | Community (Jeff Geerling, 75★) | **Active on master, but unreleased since 2021.** Last commit 2025-11-28; `pushed_at` 2025-11-28; CI matrix (master) = `rockylinux10` + `ubuntu2404`. **Last git tag `2.2.0` is 2021-04-28** — master is ~4.5 years ahead of the newest release. Scored below; the tag/master gap is a headline finding (R10). |
| [robertdebock.memcached](https://github.com/robertdebock/ansible-role-memcached) | Community (4★) | **Active but breaks on AlmaLinux.** Release `3.1.9` (2025-07-31); `min_ansible 2.12`. Selects the config template by `ansible_facts['distribution']` and ships no `AlmaLinux-memcached.j2` → fails on our primary distro. `meta` lists EL **9 only** (no EL10); molecule matrix has no AlmaLinux/EL10. Eliminated (§4). |
| linux-system-roles.* | Red Hat official | **No memcached role exists** in the linux-system-roles org (2026-08-09) — nothing official to adopt. |
| bennojoy/memcached, neoloc, devops (Galaxy mirrors) | Community | Stale / thin mirrors of the same one-file install; not evaluated in depth (nothing they add over geerlingguy). |

Only **geerlingguy.memcached** clears the bar (native package + correct EL/Debian
splits + our EL10/Ubuntu targets in CI). It is scored below.

## 3. Rubric scoring — geerlingguy.memcached (master, read 2026-08-09)

Scored from `tasks/main.yml`, `vars/RedHat.yml`, `vars/Debian.yml`,
`defaults/main.yml`, `templates/memcached-RedHat.conf.j2`,
`templates/memcached-Debian.conf.j2`, `handlers/main.yml`, `meta/main.yml`,
`.github/workflows/ci.yml` (all read 2026-08-09).

| # | Requirement | Score | Evidence (from code) |
|---|---|---|---|
| R1 | Covers both distro families (paths/units/accounts correct) | ✅ | `tasks/main.yml` does `include_vars: "{{ ansible_facts.os_family }}.yml"`. `vars/RedHat.yml`: `memcached_user: memcached`, `memcached_config_file: /etc/sysconfig/memcached` — correct for Alma 9 **and** 10. `vars/Debian.yml`: `memcached_user: memcache`, `memcached_config_file: /etc/memcached.conf` — correct for Ubuntu 24.04, including the **`memcache` (not `memcached`) account-name** divergence our footprint confirms. Accounts left to the package (correct — the package's sysusers/adduser creates them). |
| R2 | Installs + configures via native package/config mechanisms | ✅ | `package: name=memcached state=present`; config via a whole-file Jinja template to `memcached_config_file` (`owner root group root mode 0644`), then `service … state=started enabled=yes`. No source build, no vendored unit. |
| R3 | Drop-in discipline / whole-file determinism (FIM) | ⚠️ | memcached has **no `conf.d` model** (one env/args file), so a whole-file template is the only option — fine under config management (FIM accepts the rendered file). But both templates start `# {{ ansible_managed }}`, and the default `ansible_managed` embeds a timestamp → the file churns every run and trains operators to ignore FIM diffs. Strip the timestamp (the chrony/redis whole-file nuance applies — §4). |
| R4 | systemd hardening drop-ins | ❌ | No `*.service.d` drop-ins. The vendor units already ship hardening (EL: `PrivateTmp`, `ProtectSystem=full`, `PrivateDevices`, `NoNewPrivileges`; Ubuntu adds `MemoryDenyWriteExecute`, `ProtectKernel*`, `RestrictNamespaces`) — the role contributes to neither, and neither unit sets `User=` (the `service_runs_as_root` finding; see ops §11). |
| R5 | Env / secret file management | ⚠️ (mostly N/A) | memcached has **no secret surface** by default (no auth in the classic protocol; SASL is non-default). The one env/config file *is* what the role templates, so there is nothing more to manage. `defaults/main.yml` exposes `memcached_port/listen_ip/memory_limit/connections/threads/max_item_size` — a reasonable knob set. `memcached_listen_ip` defaults to `127.0.0.1` (good — the bind address is memcached's real security control). |
| R6 | **Access model** (scoped sudoers, pam_group, ACLs) | ❌ | None — no sudoers, pam/sssd, ACLs, or ownership anywhere in `tasks/`/`handlers/`. The standing all-roles-fail row; that gap is this library's job (delivered by the reviewed profiles + playbook 5). |
| R7 | Verification / idempotence quality | ✅ (with a gap) | `.github/workflows/ci.yml` molecule matrix = **`rockylinux10` + `ubuntu2404`** → covers our EL10 and Ubuntu 24.04 targets directly; role is idempotent (template + handler). Gap: **no EL9 (Alma/Rocky 9) in CI** — low risk, as EL9 shares `vars/RedHat.yml` paths with EL10, but verify out of band. |
| R8 | TLS wiring | ❌ | `defaults/main.yml` and both templates have **no** TLS directives (`-Z`/`--enable-ssl`/`-o ssl_*` absent). TLS (if the packaged binary even supports it) must be added by hand via `memcached_log_verbosity`/free-form OPTIONS. |
| R9 | logrotate policy management | ❌ (with teeth) | No logrotate handling **and** the role actively creates a rotation problem: `defaults/main.yml` sets `memcached_log_file: /var/log/memcached.log`, the Debian template writes `logfile {{ memcached_log_file }}`, and the RedHat template appends `>> {{ memcached_log_file }} 2>&1` to `OPTIONS`. So applying the role **switches memcached from journald to an unrotated `root:root` file** at `/var/log/memcached.log` — which our base profile does not grant and no logrotate trims. Decide deliberately (§6). |
| R10 | Maintenance & platform assurance for OUR versions | ⚠️ | Master is genuinely maintained (commits to 2025-11-28; CI on EL10 + Ubuntu 24.04). **But the newest git tag is `2.2.0` (2021-04-28)** and `meta/main.yml` still lists only Ubuntu precise→bionic + Debian (no EL at all). Pinning to the tag gets you 2021 code with no EL10/Ubuntu-24.04 assurance; you must pin a **commit SHA on master** instead (§6). |

## 4. Nuances found

**geerlingguy is unreleased-but-maintained — pin a SHA, not the tag.** This is
the load-bearing operational finding. `2.2.0` (2021) predates EL10, Ubuntu 24.04,
and the current CI matrix; all the coverage that makes this role adoptable lives
on **master**. Our "pin the role version" wrap rule therefore means pin a
`master` commit SHA (or a fork tag you cut), and re-verify on a bump — the tag is
a trap.

**robertdebock breaks on AlmaLinux — a concrete R1 elimination, not a style
call.** `tasks/main.yml` does `template: src: "{{ ansible_facts['distribution'] }}-memcached.j2"`.
The templates dir ships `CentOS-`, `Rocky-`, `Fedora-`, `Ubuntu-`, `Debian-`,
`Amazon-`, `Alpine-`, `Archlinux-`, `openSUSE Leap/Tumbleweed-` — but **no
`AlmaLinux-memcached.j2`**. On AlmaLinux (our primary EL distro) `ansible_facts['distribution']`
is `AlmaLinux`, so the template lookup fails and the play errors out. Its
`memcached_configfile`/`memcached_user` *vars* are correctly `os_family`-keyed, so
the break is purely the distribution-keyed template selection — but it's fatal for
us and unverified (no Alma/EL10 in its molecule matrix). Eliminated.

**The whole-file-vs-ACL collision is sharper here than for redis.** Both our
config-ACL rule and geerlingguy want to own the same single file — and unlike
redis, **memcached has no `include`/drop-in escape hatch**. With redis we handed
the team an `include`d file to own so their edits survive role re-runs; memcached
offers no such seam. So you must pick one owner:
- **role owns config** → do **not** grant the team the config write ACL; config
  changes go through a role run in a change window (drop `files_modify` from the
  applied profile with `-e '{"declarative_access_files_modify":[]}'`); or
- **team owns config post-lockdown** → keep the ACL, and do **not** re-run the
  role's config task against the host (a re-run overwrites team edits and sheds
  the ACL — re-run playbook 5 after if you do).
This tension is worth stating explicitly in the runbook; it is the one place the
minimal profile meets the role and they contend.

**The handler is `restart`, and that's correct.** `handlers/main.yml` is
`service: name=memcached state=restarted` — memcached has no `ExecReload`/graceful
reload, so restart is the only real verb, and it is the verb our profile grants.
Operators must know it **flushes the in-memory cache** (dev §2).

## 5. Verdict: adopt + wrap (geerlingguy.memcached)

1. **Adopt `geerlingguy.memcached` as the install/config engine** for **Alma 9/10
   and Ubuntu 24.04**. It is the only active, native, correct-on-all-our-targets
   option: `os_family` vars get the `memcached`/`memcache` account split and the
   `/etc/sysconfig/memcached` vs `/etc/memcached.conf` path split right, CI covers
   EL10 + Ubuntu 24.04, and it writes no sudoers/users/ACLs so it does not fight
   the read-only-units + config-ACL posture. **Pin a master commit SHA** (not the
   `2.2.0` tag — §4).
2. **Eliminate robertdebock.memcached** — its distribution-keyed template
   selection has no AlmaLinux template (breaks on our primary distro), and it
   carries no EL10 assurance. `linux-system-roles` ships nothing.
3. **Build a thin org overlay** carrying the rubric rows the role fails: R4
   (systemd hardening drop-in — or accept the vendor units' existing hardening),
   R6 (**the access model — already delivered here by the reviewed profiles +
   playbook 5**), R8 (TLS wiring if a deployment needs it, key material left to
   platform), and R9 (logrotate policy *or* the decision to keep journald).
4. **Generalize.** R4/R6/R8/R9 fail for *every* public cache/data-store role —
   the standing gap between "make the software run" and "make it operable and
   least-privilege." One reusable `org.cache_baseline` overlay parameterized per
   service covers it fleet-wide; the memcached profiles here are its R6 payload.

## 6. Running the adopted role inside our access lifecycle

The role runs during the **setup window** (executor in `<hostname>-app_full`) or
via platform automation — **always before capture**, so its outputs land in the
cairn footprint exactly like a manual install and flow through the normal
raw→reviewed step.

| Role output | Lands in footprint as | Profile key it maps to |
|---|---|---|
| `package: memcached` + vendor unit started/enabled | `memcached.service` (vendor units only — the role emits **no** unit of its own) | `declarative_access_services` (read-only-units) |
| Whole-file template at `memcached_config_file` (`root:root 0644`) | the single config file | config **write ACL** — `files_modify: ['/etc/sysconfig/memcached'/'/etc/memcached.conf']` — **but** see the ownership-collision decision (§4) |
| `memcached_log_file` default (`/var/log/memcached.log`, file logging on) | a `root:root` log **file** in `/var/log` (not a dir) | **not in the base profile** — decide: set `memcached_log_file: ""`-equivalent to keep journald, or accept the file and add a `files_read` ACL **plus** logrotate |
| `restart memcached` handler | — (runtime verb) | the granted `systemctl restart` in `_services` — the verb that matters (no graceful reload; flushes cache) |
| Package-created `memcached`/`memcache` account | account (no dirs) in footprint | **no `ownership`** — memcached owns nothing on disk |

**Wrap notes.**

- **Pin a master SHA, not `2.2.0`.** The tag predates EL10/Ubuntu 24.04; all our
  coverage is on master. A bump can change the templated output → re-capture,
  re-review, re-verify.
- **Strip the `ansible_managed` timestamp** (both template headers) so FIM stays
  quiet on repeated runs.
- **Decide the logging model deliberately.** The role's `memcached_log_file`
  default turns on **unrotated file** logging, diverging from the journald default
  our ops doc documents. Either keep journald (neutralize the `logfile`/`OPTIONS`
  redirect) or accept file logging and add both a `/var/log/memcached.log` read
  ACL and a logrotate fragment. Do not leave it defaulted and unmanaged.
- **Pick one config owner (§4).** memcached has no drop-in seam, so the team's
  config ACL and the role's whole-file template collide. Either the role owns
  config (drop the team ACL) or the team owns it post-lockdown (don't re-run the
  config task; re-run playbook 5 after any role run to reassert the ACL).
- **The role is otherwise access-model-neutral** — it writes no sudoers, users, or
  ACLs, so nothing needs disabling to stop it fighting the posture.

## 7. If nothing fits

Not applicable — geerlingguy.memcached fits as the engine. The one unbuilt piece
is the shared **`org.cache_baseline`** overlay (R4/R6/R8/R9 for every
cache/data-store): scope = optional systemd hardening drop-in + this repo's
access-profile apply (R6) + TLS wiring with key material left to platform +
logrotate policy (or an explicit keep-journald decision); distro matrix = Alma
9/10 + Ubuntu 24.04; molecule = apply-then-assert on all three. **Not scheduled** —
the access-model half (R6) already ships here as the reviewed profiles.

## 8. Sources

- https://github.com/geerlingguy/ansible-role-memcached — `tasks/main.yml`,
  `vars/RedHat.yml`, `vars/Debian.yml`, `defaults/main.yml`,
  `templates/memcached-RedHat.conf.j2`, `templates/memcached-Debian.conf.j2`,
  `handlers/main.yml`, `meta/main.yml`, `.github/workflows/ci.yml` (read
  2026-08-09); tags API (`2.2.0` = 2021-04-28, newest); commits API (last
  2025-11-28); 75★.
- https://github.com/robertdebock/ansible-role-memcached — `tasks/main.yml`,
  `vars/main.yml`, `templates/` listing (no `AlmaLinux-memcached.j2`),
  `templates/{Rocky,CentOS,Ubuntu}-memcached.j2`, `handlers/main.yml`,
  `meta/main.yml` (EL 9 only), `.github/workflows/molecule.yml`,
  `molecule/default/molecule.yml` (read 2026-08-09); releases API (`3.1.9` =
  2025-07-31); 4★.
- https://github.com/orgs/linux-system-roles/repositories — no memcached role
  present (read 2026-08-09).
- Requirement source: `profiles/memcached/*-access.yml`,
  `docs/apps/memcached/{dev,ops}.md`; footprint evidence
  `footprints/*/footprint-memcached.json`.
