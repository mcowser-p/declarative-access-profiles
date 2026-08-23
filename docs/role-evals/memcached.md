# Ansible role evaluation: memcached (AlmaLinux 9/10, Amazon Linux 2023, Ubuntu 24.04/26.04)

## 1. Method

The reviewed profiles and the [dev](../apps/memcached/dev.md)/[ops](../apps/memcached/ops.md)
docs are the requirement rubric; a public role is scored (R1–R10) on how much of
it the role delivers, read from the role's **code**, not its README. What no role
delivers becomes the spec for the org overlay. Evaluated **2026-08-09** (web-search
findings decay — dates are load-bearing); **re-read 2026-08-23** against the
five-distro KVM captures after AL2023 and Ubuntu 26.04 joined the matrix — R1/R7/R10
below reflect five distros, from the 2026-08-09 code reads plus our fresh
footprints (no new candidate research). memcached is a trivial install (one
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
| R1 | Covers both distro families (paths/units/accounts correct) | ✅ | `tasks/main.yml` does `include_vars: "{{ ansible_facts.os_family }}.yml"`. `vars/RedHat.yml`: `memcached_user: memcached`, `memcached_config_file: /etc/sysconfig/memcached` — correct for Alma 9, Alma 10 **and AL2023** (os_family `RedHat`; our 2026-08-23 AL2023 footprint shows exactly this account and path). `vars/Debian.yml`: `memcached_user: memcache`, `memcached_config_file: /etc/memcached.conf` — correct for Ubuntu 24.04 **and 26.04** (both captures confirm), including the **`memcache` (not `memcached`) account-name** divergence. Accounts left to the package (correct — the package's sysusers/adduser creates them). Five-for-five on the family-vars mapping. |
| R2 | Installs + configures via native package/config mechanisms | ✅ | `package: name=memcached state=present`; config via a whole-file Jinja template to `memcached_config_file` (`owner root group root mode 0644`), then `service … state=started enabled=yes`. No source build, no vendored unit. |
| R3 | Drop-in discipline / whole-file determinism (FIM) | ⚠️ | memcached has **no `conf.d` model** (one env/args file), so a whole-file template is the only option — fine under config management (FIM accepts the rendered file). But both templates start `# {{ ansible_managed }}`, and the default `ansible_managed` embeds a timestamp → the file churns every run and trains operators to ignore FIM diffs. Strip the timestamp (the chrony/redis whole-file nuance applies — §4). |
| R4 | systemd hardening drop-ins | ❌ | No `*.service.d` drop-ins. The vendor units already ship hardening (EL: `PrivateTmp`, `ProtectSystem=full`, `PrivateDevices`, `NoNewPrivileges`; Ubuntu adds `MemoryDenyWriteExecute`, `ProtectKernel*`, `RestrictNamespaces`) — the role contributes to neither, and neither unit sets `User=` (the `service_runs_as_root` finding; see ops §11). |
| R5 | Env / secret file management | ⚠️ (mostly N/A) | memcached has **no secret surface** by default (no auth in the classic protocol; SASL is non-default). The one env/config file *is* what the role templates, so there is nothing more to manage. `defaults/main.yml` exposes `memcached_port/listen_ip/memory_limit/connections/threads/max_item_size` — a reasonable knob set. `memcached_listen_ip` defaults to `127.0.0.1` (good — the bind address is memcached's real security control). |
| R6 | **Access model** (scoped sudoers, pam_group, ACLs) | ❌ | None — no sudoers, pam/sssd, ACLs, or ownership anywhere in `tasks/`/`handlers/`. The standing all-roles-fail row; that gap is this library's job (delivered by the reviewed profiles + playbook 5). |
| R7 | Verification / idempotence quality | ⚠️ | `.github/workflows/ci.yml` molecule matrix = **`rockylinux10` + `ubuntu2404`** → direct CI cover for **2 of our 5 cells** (EL10 and Ubuntu 24.04); role is idempotent (template + handler). No EL9, no Amazon Linux, no Ubuntu 26.04 anywhere in the matrix. Low mechanical risk — all five ride the two `os_family` vars files R1 confirms — but 3 of 5 cells are ours to verify out of band (was "✅ with a gap" when the gap was 1 of 3; at 3 of 5 it's the majority). |
| R8 | TLS wiring | ❌ | `defaults/main.yml` and both templates have **no** TLS directives (`-Z`/`--enable-ssl`/`-o ssl_*` absent). TLS (if the packaged binary even supports it) must be added by hand via `memcached_log_verbosity`/free-form OPTIONS. |
| R9 | logrotate policy management | ❌ (with teeth) | No logrotate handling **and** the role actively creates a rotation problem: `defaults/main.yml` sets `memcached_log_file: /var/log/memcached.log`, the Debian template writes `logfile {{ memcached_log_file }}`, and the RedHat template appends `>> {{ memcached_log_file }} 2>&1` to `OPTIONS`. So applying the role **switches memcached from journald to an unrotated `root:root` file** at `/var/log/memcached.log` — which our base profile does not grant and no logrotate trims. Decide deliberately (§6b). |
| R10 | Maintenance & platform assurance for OUR versions | ⚠️ | Master is genuinely maintained (commits to 2025-11-28; CI on EL10 + Ubuntu 24.04). **But the newest git tag is `2.2.0` (2021-04-28)** and `meta/main.yml` still lists only Ubuntu precise→bionic + Debian (no EL, no Amazon Linux). Across the five-distro matrix the upstream assurance story is: tag = none; master = EL10 + Ubuntu 24.04 only; **AL2023 and Ubuntu 26.04 appear nowhere upstream** — their only assurance is our own footprints + verify pass. Pin a **commit SHA on master**, never the tag (§6a). |

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

1. **Adopt `geerlingguy.memcached` as the install/config engine** for all five
   matrix distros — **Alma 9/10, AL2023, Ubuntu 24.04/26.04**. It is the only
   active, native, correct-on-all-our-targets option: the two `os_family` vars
   files get the `memcached`/`memcache` account split and the
   `/etc/sysconfig/memcached` vs `/etc/memcached.conf` path split right on every
   cell (R1 — our five footprints confirm the mapping), and it writes no
   sudoers/users/ACLs so it does not fight the read-only-units + config-ACL
   posture. Upstream CI only exercises EL10 + Ubuntu 24.04, so EL9, AL2023 and
   26.04 are verified by our own pass (R7/R10). **Pin a master commit SHA** (not
   the `2.2.0` tag — §4).
2. **Eliminate robertdebock.memcached** — its distribution-keyed template
   selection has no AlmaLinux template (breaks on our primary distro), and it
   carries no EL10 assurance. (Its templates dir does ship an
   `Amazon-memcached.j2`, so AL2023 alone would work — irrelevant, since Alma
   is fatal.) `linux-system-roles` ships nothing.
3. **Build a thin org overlay** carrying the rubric rows the role fails: R4
   (systemd hardening drop-in — or accept the vendor units' existing hardening),
   R6 (**the access model — already delivered here by the reviewed profiles +
   playbook 5**), R8 (TLS wiring if a deployment needs it, key material left to
   platform), and R9 (logrotate policy *or* the decision to keep journald).
4. **Generalize.** R4/R6/R8/R9 fail for *every* public cache/data-store role —
   the standing gap between "make the software run" and "make it operable and
   least-privilege." One reusable `org.cache_baseline` overlay parameterized per
   service covers it fleet-wide; the memcached profiles here are its R6 payload.

## 6. Implementing least privilege with this role

From "we picked geerlingguy.memcached" to "the team is locked down and knows
how to operate", in four steps.

### 6a. Where the role runs in the lifecycle

The role runs during the **setup window** (executor in `<hostname>-app_full`) or
via platform automation — **always before capture**, so its outputs land in the
treadmark footprint exactly like a manual install and flow through the normal
raw→reviewed step.

| Role output | Lands in footprint as | Profile key it maps to |
|---|---|---|
| `package: memcached` + vendor unit started/enabled | `memcached.service` (vendor units only — the role emits **no** unit of its own) | `declarative_access_services` (read-only-units) |
| Whole-file template at `memcached_config_file` (`root:root 0644`) | the single config file | config **write ACL** — `files_modify: ['/etc/sysconfig/memcached'/'/etc/memcached.conf']` — **but** see the config-owner decision (6b) |
| `memcached_log_file` default (`/var/log/memcached.log`, file logging on) | a `root:root` log **file** in `/var/log` (not a dir) | **not in the base profile** — the logging-model decision (6b) |
| `restart memcached` handler | — (runtime verb) | the granted `systemctl restart` in `_services` — the verb that matters (no graceful reload; flushes cache) |
| Package-created `memcached`/`memcache` account | account (no dirs) in footprint | **no `ownership`** — memcached owns nothing on disk |

**Wrap notes.**

- **Pin a master SHA, not `2.2.0`.** The tag predates EL10/Ubuntu 24.04 (and
  AL2023/26.04 entirely); all our coverage is on master. A version bump can
  change the templated output → re-capture, re-review, re-verify.
- **Strip the `ansible_managed` timestamp** (both template headers) so FIM stays
  quiet on repeated runs.
- **Re-running the role post-lockdown is a platform act**, not a team one — and
  a run that rewrites the config file **sheds the team's ACL**. Re-run playbook 5
  after (idempotent), and see the config-owner decision in 6b.

### 6b. Configuring the deployment for least privilege

The vars that keep the install compatible with the profile, from the role's own
code (2026-08-09 reads):

- **Config stays root-owned — nothing to disable.** The template task writes
  `memcached_config_file` as `owner: root, group: root, mode: 0644`, and the
  role creates no sudoers, users, or ACLs anywhere in `tasks/`/`handlers/` (R6)
  — it is access-model-neutral out of the box.
- **Run as the packaged system account.** Leave `memcached_user` at the family
  default (`memcached` on EL-family, `memcache` on Debian-family — `vars/*.yml`);
  never point it at a login user. On EL it lands as `USER=` in
  `/etc/sysconfig/memcached`, i.e. the `-u` privilege drop the vendor unit is
  built around (ops §11).
- **Port/capability posture: nothing needed.** `memcached_port` defaults to
  `11211` (>1024 — no `CAP_NET_BIND_SERVICE` question); the vendor unit's
  `CAP_SETUID/SETGID` exist for the `-u` drop, not port binding. Keep
  `memcached_listen_ip: 127.0.0.1` (the role's default) — the bind address is
  memcached's only access control (dev §7).
- **Keep the packaged logging model so the log grants hold** — here that model
  is **the journal**. The role's `memcached_log_file` default
  (`/var/log/memcached.log`) switches memcached to an **unrotated `root:root`
  file** the profile does not grant (R9). Either neutralize it (empty the
  Debian template's `logfile` line / the RedHat `OPTIONS` redirect) or accept
  file logging deliberately and re-review: a `files_read` ACL on the file
  **plus** a logrotate fragment (ops §10). Do not leave it defaulted.
- **Pick one config owner (§4).** memcached has no drop-in seam, so the team's
  config ACL and the role's whole-file template contend for the same file.
  Either the **role owns config** — then drop the team ACL at apply time
  (`-e '{"declarative_access_files_modify":[]}'`) and config changes go through
  role runs in change windows — or the **team owns config post-lockdown** —
  then keep the ACL, stop re-running the config task, and re-run playbook 5
  after any role run.
- **Secrets: nothing to manage** (R5) — no auth in the classic protocol, SASL
  non-default. TLS wiring is **not expressible with this role** (R8): no TLS
  vars exist; if a deployment needs `-Z`/`-o ssl_*`, that is free-form OPTIONS
  plus platform-owned key placement (ops §9).

### 6c. Applying the access profile

Once the role has deployed and the capture is reviewed, lock down with playbook
5 (`5_apply_access_profile.yml`) and this app's reviewed profile, then run the
verify pass and flip the team out of app-full — the full runbook is
[ops §4–§6](../apps/memcached/ops.md#4-apply):

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/memcached/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
```

### 6d. Who does what after lockdown

**The application team** operates from the [dev guide](../apps/memcached/dev.md)
— "your life after lockdown": the granted `systemctl` verb set on
`memcached.service` (knowing restart flushes the cache and reload does nothing),
the exact `journalctl -u memcached` spellings, and the one config file their ACL
covers (`/etc/sysconfig/memcached` / `/etc/memcached.conf`), edited via the
restart-and-check cycle in dev §3.

**The operations team** works from the [ops runbook](../apps/memcached/ops.md):
the footprint evidence (§1), the raw→reviewed decisions (§2), apply/verify/flip
(§4–§6), revoke and drift (§7–§8), and the risk triage — including the accepted
`service_runs_as_root` finding and its runtime confirmation (§11).

## 7. If nothing fits

Not applicable — geerlingguy.memcached fits as the engine. The one unbuilt piece
is the shared **`org.cache_baseline`** overlay (R4/R6/R8/R9 for every
cache/data-store): scope = optional systemd hardening drop-in + this repo's
access-profile apply (R6) + TLS wiring with key material left to platform +
logrotate policy (or an explicit keep-journald decision); distro matrix = the
five matrix distros (Alma 9/10, AL2023, Ubuntu 24.04/26.04); molecule =
apply-then-assert on all five. **Not scheduled** — the access-model half (R6)
already ships here as the reviewed profiles.

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
