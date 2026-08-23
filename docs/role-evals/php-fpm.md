# Ansible role evaluation: php-fpm (AlmaLinux 9/10 + AL2023 + Ubuntu 24.04/26.04)

## 1. Method

The reviewed profiles and the [dev](../apps/php-fpm/dev.md)/[ops](../apps/php-fpm/ops.md)
docs are the requirement rubric; a public role is scored (R1–R10) on how
much of it the role delivers, read from the role's **code**, not its README.
What no role delivers becomes the spec for the org overlay. Evaluated
**2026-08-09** (web-search findings decay — dates are load-bearing).
Re-scoped **2026-08-23** when the matrix grew to five distros
(amazonlinux-2023 and ubuntu-26.04 joined on the KVM substrate): R1/R7/R10
were re-scored against the five-distro reality from the same role code read
2026-08-09; candidate research was **not** re-run.

A framing note specific to this app: php-fpm is the **PHP engine**, not the
web server. "Install and configure php-fpm" means the FPM daemon and its
pools; TLS and the document root belong to the web-server role in front (see
[apache eval](apache.md) / the nginx eval). The rubric's R8 (TLS) is scored
**N/A** here for that reason.

## 2. Candidates

| Role | Backing | Status (verified via repo API, 2026-08-09) |
|---|---|---|
| [geerlingguy.php](https://github.com/geerlingguy/ansible-role-php) | Community (Jeff Geerling), 513★/463 forks | **Active** — v6.1.0, pushed 2026-06-09, 12 open issues, not archived. The de-facto PHP/FPM role. Scored below. |
| [geerlingguy.apache-php-fpm](https://github.com/geerlingguy/ansible-role-apache-php-fpm) | Community, 42★/33 forks | **Active** (pushed 2025-11-28) but a **glue role** — wires *Apache* to talk to FPM; depends on `geerlingguy.apache` and assumes FPM is installed elsewhere (by `geerlingguy.php`). Complement, not a substitute. Not scored as the engine. |
| [angristan.php-fpm](https://github.com/angristan/ansible-php-fpm) | Community, 13★ | **Stale + Debian-only** — pushed 2020-04; topics `debian/ubuntu`, no EL. Eliminated (fails R1 for our EL family). |
| [davidalger.php-fpm](https://github.com/davidalger/ansible-role-php-fpm) | Community, 2★ | **Stale + EL-only via IUS** — pushed 2020-07; "PHP-FPM from IUS RPMs for RHEL/CentOS". IUS is legacy/EOL and there is no Debian path. Eliminated. |
| criecm, petemcw, Yannik, chusiang (php7) | Community | Niche/inactive/single-family. Not evaluated in depth. |
| linux-system-roles.* | Red Hat official | **No PHP/php-fpm role exists** in the linux-system-roles org (2026-08-09) — as with Apache, there is nothing official to adopt. |

Only **geerlingguy.php** clears the bar (active + both distro families +
implements FPM itself). It is scored below.

## 3. Rubric scoring — geerlingguy.php @ v6.1.0

Scored from `tasks/configure-fpm.yml`, `templates/www.conf.j2`,
`vars/RedHat.yml`, `vars/Debian.yml`, `defaults/main.yml`, `meta/main.yml`,
and `.github/workflows/ci.yml` (read 2026-08-09).

| # | Requirement | Score | Evidence (from code) |
|---|---|---|---|
| R1 | Covers both distro families (paths/units/accounts correct) | ⚠️ | `vars/RedHat.yml` is correct for our EL captures: `php_fpm_daemon: php-fpm`, `php_fpm_pool_conf_path: /etc/php-fpm.d/www.conf`, pool user/group `apache` — and because **AL2023 keeps the same unversioned unit/config layout** ([ops §1](../apps/php-fpm/ops.md#1-footprint-summary-evidence)), those vars describe it too; what the code read did **not** establish is whether the role's RedHat *package list* resolves against AL2023's versioned package names (`php8.4-*` — there is no unversioned `php-fpm` package there). `vars/Debian.yml` sets `__php_default_version_debian: 8.2` → daemon `php8.2-fpm`, pool `/etc/php/8.2/fpm/pool.d`, `www-data`. Our captured Ubuntu targets are **8.3** (24.04) and **8.5** (26.04) — set `php_default_version_debian` per release or the role diverges from the footprint (8.5 presence in v6.1.0's version handling is unverified). Accounts come from the package (role adds none — correct). |
| R2 | Installs + configures via native package/config mechanisms | ✅ | `package` install; `tasks/configure-fpm.yml` ensures the pool dir (`0755`) and templates each pool from `www.conf.j2` into `{{ pool_conf_path \| dirname }}/{{ item.pool_name }}.conf` at `root:root 0644`; php.ini tuned via the role's ini tasks. Native, no from-source drift. |
| R3 | Drop-in discipline / whole-file determinism (FIM) | ⚠️ | Writes a **per-pool file** into the pool dir (a drop-in, never the vendor `php-fpm.conf`) — good. But `www.conf.j2` opens with `{{ ansible_managed \| comment(decoration='; ') }}`; the **default `ansible_managed` carries a timestamp**, so every run rewrites the pool file and trains operators to ignore FIM diffs. Set `ansible_managed` to a static string (the chrony/apache whole-file nuance — §4). |
| R4 | systemd hardening drop-ins | ❌ | No `*.service.d` drop-ins. Leaves the vendor unit as-is (master runs as root — [ops §11](../apps/php-fpm/ops.md#11-known-risks-from-risks)). |
| R5 | Env / secret file management | ❌ | No `/etc/sysconfig/php-fpm` / `envvars` handling. Per-pool `env[...]` is only what you place in a `php_fpm_pools` item, rendered into the world-readable pool file. |
| R6 | **Access model** (scoped sudoers, pam_group, ACLs) | ❌ | None — `configure-fpm.yml` writes `root:root 0644` config and no sudoers/pam/ACL/ownership anywhere. The standing all-roles-fail row; that gap is this library's job (delivered by the reviewed profiles + playbook 5). |
| R7 | Verification / idempotence quality | ⚠️ | Molecule matrix is **Debian 11/12/13 + Ubuntu 22.04/24.04**; **Rocky 9 is commented out** (referencing an upstream issue) and there is **no EL10, no Amazon Linux, no Ubuntu 26.04**. Of our five targets, only **Ubuntu 24.04** is in upstream CI — alma9, alma10, AL2023, and 26.04 are all untested upstream. Idempotent by the usual Geerling standard. |
| R8 | TLS wiring | N/A | php-fpm terminates no TLS — it speaks FastCGI to the web server over a local socket. The role correctly emits no cert/key config. TLS is the web-server role's requirement ([tls-ssl.md](../concepts/tls-ssl.md)); not a php-fpm gap. |
| R9 | logrotate policy management | ❌ | No logrotate handling. Worse for observability: `www.conf.j2` sets **no `error_log`/`access.log`/`slowlog`**, so file logging is left entirely to the package defaults + global `php-fpm.conf`. |
| R10 | Maintenance & platform assurance for OUR versions | ⚠️ | Actively maintained (v6.1.0, 2026-06), and Ubuntu 24.04 is a first-class CI target. But `meta/main.yml` platforms list only **Fedora/Debian/Ubuntu** (no EL, no Amazon Linux), CI dropped EL (Rocky 9 commented, no EL10) and predates 26.04, and the Debian default is PHP **8.2** not our 8.3/8.5. **Before rollout: verify Alma 9, Alma 10, and AL2023 in molecule (on AL2023 also that the package names resolve — see R1), pin PHP 8.3 on noble, and confirm v6.1.0 handles 8.5 on 26.04.** |

## 4. Nuances found

**The `ansible_managed` timestamp is the real FIM trap (mirrors chrony/apache).**
The pool file is a drop-in, so under config management Ansible owns it and
the FIM baseline can accept the *rendered* version — a stronger property than
hand-edited pool files, exactly as in the [apache eval §4](apache.md). The
catch is specific: `www.conf.j2` embeds `ansible_managed`, whose default
value includes a timestamp, so a re-run churns the file and any drift signal
drowns. Fix is one line — set `ansible_managed = "Ansible managed"` (static)
— and then the whole-file-under-config-management reasoning holds.

**The role owns config the profile then ACLs to the team.** Post-lockdown the
reviewed profile hands the team a **write ACL on the pool dir**, so they edit
pools the role no longer knows about. Not a conflict: the role runs in the
setup window *before* capture; after lockdown the pool dir is the team's
(tracked by ACL), not the role's (§6).

**PHP version is a footprint-defining choice on Debian.** Ubuntu 24.04 ships
native PHP 8.3 and 26.04 ships native 8.5; the role defaults Debian to 8.2
(which on either release means pulling the ondrej/sury repo). To reproduce
our captured **native** footprints, set `php_default_version_debian: "8.3"`
(noble) / `"8.5"` (26.04 — unverified in v6.1.0, see R1) and keep the distro
repo. A version change here changes the unit name and the entire config path
(`/etc/php/8.X/fpm/pool.d`) — re-capture and re-review, don't just re-apply
([ops §8](../apps/php-fpm/ops.md#8-drift-and-patching)). **AL2023 inverts
the trap:** the version lives in the *package name* (`php8.4-fpm`) while
unit and config paths stay unversioned, so a stream switch leaves the
role's `vars/RedHat.yml` paths and our grants intact but still changes the
footprint (package set + `/usr/lib64/php8.X/modules`) — re-capture, expect a
no-op review.

**No file-log paths in the pool template.** Because `www.conf.j2` sets no
`error_log`, FPM falls back to the global log — `/var/log/php-fpm/` on EL
(covered by our directory read ACL) and the single file `/var/log/php8.3-fpm.log`
on Ubuntu (the rotation caveat in [ops §10](../apps/php-fpm/ops.md#10-logs)).
A team wanting default-ACL'd file logs on Ubuntu should template a pool
`error_log` into a dedicated dir.

## 5. Verdict: adopt + wrap

1. **Adopt `geerlingguy.php` as the install/config engine.** It is the only
   active, two-family, natively-implemented PHP/FPM option (no official Red
   Hat role exists; the community alternatives are stale and single-family).
   Its pool config is a drop-in, and it correctly leaves accounts and key
   material to the platform/package. **Pin `v6.1.0`.** Action items before
   rollout: (a) run molecule on **AlmaLinux 9, AlmaLinux 10, and AL2023** —
   upstream CI omits the whole EL family, and on AL2023 also confirm the
   role's RedHat package list resolves against the versioned `php8.4-*`
   names (R1); (b) set `php_default_version_debian` per release — `"8.3"` on
   noble, `"8.5"` on 26.04 (confirm v6.1.0 accepts it) — so each Ubuntu
   footprint matches our capture; (c) make `ansible_managed` static.
2. **Build a thin org overlay** carrying exactly the rows the role fails: R4
   (systemd hardening drop-in), R5 (env/pool-secret hygiene), R6 (**the
   access model — already delivered by this repo's reviewed profiles +
   playbook 5**), and R9 (logrotate policy + explicit pool `error_log`).
3. **Generalize.** R4/R5/R6/R9 fail for *every* public web-tier role — the
   standing gap between "make the software run" and "make it operable and
   least-privilege." One reusable overlay parameterized per service covers it
   fleet-wide; the php-fpm profiles here are its R6 payload.

## 6. Implementing least privilege with this role

Four steps take a team from "we picked geerlingguy.php" to "the team is
locked down and knows how to operate."

### 6a. Where the role runs in the lifecycle

The role runs during the **setup window** (executor in `<hostname>-app_full`)
or via platform automation — **always before capture**, so its outputs land
in the treadmark footprint exactly like a manual install and flow through the
normal raw→reviewed step.

| Role output | Lands in footprint as | Profile key it maps to |
|---|---|---|
| php-fpm package + vendor unit (`php-fpm.service` on EL/AL2023; `php8.3-fpm.service` / `php8.5-fpm.service` on Ubuntu) | `systemd_unit` (vendor) | `declarative_access_services` (read-only-units — the role emits **no** units of its own) |
| Templated pool file(s) in the pool dir (`root:root 0644`) | config-tree files | config **write ACL** — `folders_modify: ['/etc/php-fpm.d'` / `'/etc/php/8.3/fpm/pool.d'` / `'/etc/php/8.5/fpm/pool.d']` |
| php.ini / extension `.ini` edits (shared SAPIs) | modified `/etc/php.ini`, `/etc/php.d/*` | **not granted** — shared with the CLI SAPI; the role edits it in the setup window, the team does not own it after lockdown |
| pool `user`/`group` (`apache`/`www-data`) | pool file content + `root:apache` state dirs | **no pam_group** by default (the whole point of this app's review — [ops §2/§3](../apps/php-fpm/ops.md#2-raw-reviewed-the-decisions)); apply-time opt-in only |
| `restart php-fpm` handler | — (runtime verb) | the granted `systemctl reload`/`restart` in the `_services` sudoers — the verb that matters for pool pickup |
| Installed PHP extensions (`php-<ext>`) | extra `binary`/`library`/`config` files | **re-capture + re-review** (new footprint) if changed after baseline |

**Wrap notes.**

- **Pin the role version.** A bump can change the pool template or add files →
  re-capture, re-review, re-verify. `v6.1.0` is the pinned baseline.
- **Re-running post-lockdown is a platform act.** A later role run rewrites
  the ACL'd pool file and sheds its ACL — **re-run playbook 5 afterward**
  (idempotent) to reassert the config ACL.

### 6b. Configuring the deployment for least privilege

The vars and app config that keep the install least-priv-compatible, scored
from the role's own code (read 2026-08-09):

- **Config stays root-owned — the role's default; keep it.**
  `configure-fpm.yml` templates pool files `root:root 0644` and writes no
  sudoers, users, or groups, so there is no behavior to disable — and none
  to add: the pool dir must stay team-written (ACL), never chowned to
  `apache`/`www-data` ([ops §2](../apps/php-fpm/ops.md#2-raw-reviewed-the-decisions)).
- **Run as the packaged pool account.** Leave the pool `user`/`group` at the
  distro defaults the role loads from `vars/RedHat.yml` / `vars/Debian.yml`
  (`apache` / `www-data`) — never a login user.
- **Pin the PHP version per distro.** `php_default_version_debian: "8.3"`
  (noble) / `"8.5"` (26.04 — unverified in v6.1.0, R1); EL/AL2023 take the
  distro stream (AL2023: confirm package-name resolution, R1).
- **Ports and capabilities: nothing to configure.** FPM listens on a local
  Unix socket (`/run/php-fpm/*.sock` / `127.0.0.1:9000`) — no <1024 port,
  no `CAP_NET_BIND_SERVICE` posture. [app-knowledge]
- **Log to the packaged sinks so the profile's log grants hold.** The role's
  `www.conf.j2` sets no `error_log`/`access.log` (R9), so FPM falls back to
  the packaged global log — `/var/log/php-fpm/` on the EL family (inside the
  granted dir ACL) and the flat `/var/log/php8.X-fpm.log` on Ubuntu (granted
  file ACL, rotation caveat). For default-ACL'd file logs on Ubuntu,
  template a pool `error_log` into a dedicated dir and have ops grant it
  ([ops §10](../apps/php-fpm/ops.md#10-logs)).
- **Secrets: not expressible with this role** (R5 ❌). Anything placed in a
  `php_fpm_pools` item's `env[...]` renders into the world-readable `0644`
  pool file — keep real secrets in the application's own secret mechanism,
  never the pool file.
- **Make the render deterministic.** Set `ansible_managed` static so the
  pool file doesn't churn every run and FIM drift stays visible (R3, §4).

### 6c. Applying the access profile

Once the role has deployed and capture/review is done, lockdown is one
playbook run with this app's reviewed profile, followed by the verify pass
and the flip out of app-full:

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/php-fpm/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted"
```

The full runbook — apply artifacts, allow/deny probes, flip, revoke — lives
in [ops §4–§7](../apps/php-fpm/ops.md#4-apply); it is not duplicated here.

### 6d. Who does what after lockdown

**The application team** operates from the [dev guide](../apps/php-fpm/dev.md)
— "your life after lockdown": the granted `systemctl` verbs and `journalctl`
spellings (verbatim from `sudo -l`), pool edits under the config ACL
(`/etc/php-fpm.d` / `/etc/php/8.X/fpm/pool.d`), log reading, and the
change-window path for everything outside the grant (shared `php.ini`,
extensions, PHP version bumps).

**The operations team** works from the [ops runbook](../apps/php-fpm/ops.md):
the footprint evidence (§1), the raw→reviewed decisions (§2),
apply/verify/flip/revoke (§4–§7), drift and patching after package updates
or role re-runs (§8), and the `risks[]` triage (§11).

## 7. If nothing fits

Not applicable — geerlingguy.php fits as the engine. The only unbuilt piece
is the shared **`org.web_baseline`** overlay (R4/R5/R6/R9 for every web-tier
service, php-fpm included): scope = hardening drop-in + env/pool-secret
hygiene + this repo's access-profile apply + logrotate policy with an
explicit pool `error_log`; distro matrix = the library's five (Alma 9/10,
AL2023, Ubuntu 24.04/26.04); molecule = apply-then-assert on all five
(upstream CI covers only Ubuntu 24.04 of them). Two paragraphs of spec,
**not scheduled** — the access-model half (R6) already ships here as the
reviewed profiles.

## 8. Sources

- https://github.com/geerlingguy/ansible-role-php — `tasks/configure-fpm.yml`,
  `templates/www.conf.j2`, `vars/RedHat.yml`, `vars/Debian.yml`,
  `defaults/main.yml`, `meta/main.yml`, `.github/workflows/ci.yml`
  (read 2026-08-09); repo API (513★, pushed 2026-06-09, not archived, 12 open
  issues); tags API (newest v6.1.0).
- https://github.com/geerlingguy/ansible-role-apache-php-fpm — repo API
  (42★, pushed 2025-11-28; glue role for Apache; read 2026-08-09).
- https://github.com/angristan/ansible-php-fpm — repo API (13★, pushed
  2020-04, Debian/Ubuntu only; read 2026-08-09).
- https://github.com/davidalger/ansible-role-php-fpm — repo API (2★, pushed
  2020-07, IUS RPMs RHEL/CentOS only; read 2026-08-09).
- https://github.com/orgs/linux-system-roles/repositories — no php/php-fpm
  role present (read 2026-08-09).
- Requirement source: `profiles/php-fpm/*-access.yml` (five distros),
  `docs/apps/php-fpm/{dev,ops}.md`.
- 2026-08-23 five-distro re-scope: **no new external sources** — R1/R7/R10
  re-scored from the 2026-08-09 code reading; the AL2023 and ubuntu-26.04
  facts come from `footprints/{amazonlinux-2023,ubuntu-26.04}/footprint-php-fpm.json`
  and [ops §1](../apps/php-fpm/ops.md#1-footprint-summary-evidence).
