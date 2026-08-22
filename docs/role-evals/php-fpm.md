# Ansible role evaluation: php-fpm (AlmaLinux 9/10 + Ubuntu 24.04)

## 1. Method

The reviewed profiles and the [dev](../apps/php-fpm/dev.md)/[ops](../apps/php-fpm/ops.md)
docs are the requirement rubric; a public role is scored (R1–R10) on how
much of it the role delivers, read from the role's **code**, not its README.
What no role delivers becomes the spec for the org overlay. Evaluated
**2026-08-09** (web-search findings decay — dates are load-bearing).

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
| R1 | Covers both distro families (paths/units/accounts correct) | ⚠️ | `vars/RedHat.yml` is correct for our EL capture: `php_fpm_daemon: php-fpm`, `php_fpm_pool_conf_path: /etc/php-fpm.d/www.conf`, pool user/group `apache`. `vars/Debian.yml` sets `__php_default_version_debian: 8.2` → daemon `php8.2-fpm`, pool `/etc/php/8.2/fpm/pool.d`, `www-data`. Our captured Ubuntu target is **8.3** — you must set `php_default_version_debian: "8.3"` or the role diverges from the footprint. Accounts come from the package (role adds none — correct). |
| R2 | Installs + configures via native package/config mechanisms | ✅ | `package` install; `tasks/configure-fpm.yml` ensures the pool dir (`0755`) and templates each pool from `www.conf.j2` into `{{ pool_conf_path | dirname }}/{{ item.pool_name }}.conf` at `root:root 0644`; php.ini tuned via the role's ini tasks. Native, no from-source drift. |
| R3 | Drop-in discipline / whole-file determinism (FIM) | ⚠️ | Writes a **per-pool file** into the pool dir (a drop-in, never the vendor `php-fpm.conf`) — good. But `www.conf.j2` opens with `{{ ansible_managed \| comment(decoration='; ') }}`; the **default `ansible_managed` carries a timestamp**, so every run rewrites the pool file and trains operators to ignore FIM diffs. Set `ansible_managed` to a static string (the chrony/apache whole-file nuance — §4). |
| R4 | systemd hardening drop-ins | ❌ | No `*.service.d` drop-ins. Leaves the vendor unit as-is (master runs as root — [ops §11](../apps/php-fpm/ops.md#11-known-risks-from-risks)). |
| R5 | Env / secret file management | ❌ | No `/etc/sysconfig/php-fpm` / `envvars` handling. Per-pool `env[...]` is only what you place in a `php_fpm_pools` item, rendered into the world-readable pool file. |
| R6 | **Access model** (scoped sudoers, pam_group, ACLs) | ❌ | None — `configure-fpm.yml` writes `root:root 0644` config and no sudoers/pam/ACL/ownership anywhere. The standing all-roles-fail row; that gap is this library's job (delivered by the reviewed profiles + playbook 5). |
| R7 | Verification / idempotence quality | ⚠️ | Molecule matrix is **Debian 11/12/13 + Ubuntu 22.04/24.04**; **Rocky 9 is commented out** (referencing an upstream issue) and there is **no EL10**. So Ubuntu 24.04 is covered but **both our EL targets are untested upstream**. Idempotent by the usual Geerling standard. |
| R8 | TLS wiring | N/A | php-fpm terminates no TLS — it speaks FastCGI to the web server over a local socket. The role correctly emits no cert/key config. TLS is the web-server role's requirement ([tls-ssl.md](../concepts/tls-ssl.md)); not a php-fpm gap. |
| R9 | logrotate policy management | ❌ | No logrotate handling. Worse for observability: `www.conf.j2` sets **no `error_log`/`access.log`/`slowlog`**, so file logging is left entirely to the package defaults + global `php-fpm.conf`. |
| R10 | Maintenance & platform assurance for OUR versions | ⚠️ | Actively maintained (v6.1.0, 2026-06), and Ubuntu 24.04 is a first-class CI target. But `meta/main.yml` platforms list only **Fedora/Debian/Ubuntu** (no EL), CI dropped EL (Rocky 9 commented, no EL10), and the Debian default is PHP **8.2** not our 8.3. **Verify Alma 9 + Alma 10 in molecule and pin PHP 8.3 on noble before rollout.** |

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
native PHP 8.3; the role defaults Debian to 8.2 (which on noble means pulling
the ondrej/sury repo). To reproduce our captured **native `php8.3-fpm`**
footprint, set `php_default_version_debian: "8.3"` and keep the distro repo.
A version change here changes the unit name and the entire config path
(`/etc/php/8.X/fpm/pool.d`) — re-capture and re-review, don't just re-apply
([ops §8](../apps/php-fpm/ops.md#8-drift-and-patching)).

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
   rollout: (a) run molecule on **AlmaLinux 9 and 10** — upstream CI omits EL
   entirely; (b) set `php_default_version_debian: "8.3"` so the Ubuntu
   footprint matches our capture; (c) make `ansible_managed` static.
2. **Build a thin org overlay** carrying exactly the rows the role fails: R4
   (systemd hardening drop-in), R5 (env/pool-secret hygiene), R6 (**the
   access model — already delivered by this repo's reviewed profiles +
   playbook 5**), and R9 (logrotate policy + explicit pool `error_log`).
3. **Generalize.** R4/R5/R6/R9 fail for *every* public web-tier role — the
   standing gap between "make the software run" and "make it operable and
   least-privilege." One reusable overlay parameterized per service covers it
   fleet-wide; the php-fpm profiles here are its R6 payload.

## 6. Running the adopted role inside our access lifecycle

The role runs during the **setup window** (executor in `<hostname>-app_full`)
or via platform automation — **always before capture**, so its outputs land
in the treadmark footprint exactly like a manual install and flow through the
normal raw→reviewed step.

| Role output | Lands in footprint as | Profile key it maps to |
|---|---|---|
| php-fpm package + vendor unit (`php-fpm.service` / `php8.3-fpm.service`) | `systemd_unit` (vendor) | `declarative_access_services: ['php-fpm']` (read-only-units — the role emits **no** units of its own) |
| Templated pool file(s) in the pool dir (`root:root 0644`) | config-tree files | config **write ACL** — `folders_modify: ['/etc/php-fpm.d'` / `'/etc/php/8.3/fpm/pool.d']` |
| php.ini / extension `.ini` edits (shared SAPIs) | modified `/etc/php.ini`, `/etc/php.d/*` | **not granted** — shared with the CLI SAPI; the role edits it in the setup window, the team does not own it after lockdown |
| pool `user`/`group` (`apache`/`www-data`) | pool file content + `root:apache` state dirs | **no pam_group** by default (the whole point of this app's review — [ops §2/§3](../apps/php-fpm/ops.md#2-raw--reviewed-the-decisions)); apply-time opt-in only |
| `restart php-fpm` handler | — (runtime verb) | the granted `systemctl reload`/`restart` in the `_services` sudoers — the verb that matters for pool pickup |
| Installed PHP extensions (`php-<ext>`) | extra `binary`/`library`/`config` files | **re-capture + re-review** (new footprint) if changed after baseline |

**Wrap notes.**

- **Pin the role version.** A bump can change the pool template or add files →
  re-capture, re-review, re-verify. `v6.1.0` is the pinned baseline.
- **Make the render deterministic.** Set `ansible_managed` static so the
  pool file doesn't churn every run (FIM stays quiet) — the one thing the
  role does that fights a FIM baseline.
- **Don't let the role widen the model — it doesn't by default.** It writes
  config `root:root` (never chowns to the service account) and writes no
  sudoers/users/groups (confirmed in `configure-fpm.yml`), so the config-ACL +
  read-only-units posture holds. Keep the pam_group opt-in *off* unless a
  co-located host genuinely needs it.
- **Re-running post-lockdown is a platform act.** A later role run rewrites
  the ACL'd pool file and sheds its ACL — **re-run playbook 5 afterward**
  (idempotent) to reassert the config ACL.

## 7. If nothing fits

Not applicable — geerlingguy.php fits as the engine. The only unbuilt piece
is the shared **`org.web_baseline`** overlay (R4/R5/R6/R9 for every web-tier
service, php-fpm included): scope = hardening drop-in + env/pool-secret
hygiene + this repo's access-profile apply + logrotate policy with an
explicit pool `error_log`; distro matrix = Alma 9/10 + Ubuntu 24.04;
molecule = apply-then-assert on all three (the EL coverage upstream lacks).
Two paragraphs of spec, **not scheduled** — the access-model half (R6)
already ships here as the reviewed profiles.

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
- Requirement source: `profiles/php-fpm/*-access.yml`,
  `docs/apps/php-fpm/{dev,ops}.md`.
