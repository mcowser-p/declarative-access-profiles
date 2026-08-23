# Distro adaptation map: EL ↔ Ubuntu ↔ Amazon Linux (verified 2026-08)

The differences that change profiles and docs between AlmaLinux 9/10,
Ubuntu 24.04/26.04, and Amazon Linux 2023. Every dev/ops doc's §7 distro
table draws from here. (Package facts re-verified 2026-08-23 by recon on
the holy-qcow KVM images.)

## Packages, units, accounts

| Thing | EL 9/10 | Ubuntu 24.04 | Ubuntu 26.04 | AL2023 |
| --- | --- | --- | --- | --- |
| Apache | pkg `httpd`, unit `httpd.service`, user/group `apache` | pkg `apache2`, unit `apache2.service`, user/group `www-data` | same as 24.04 | same as EL |
| Tomcat | `tomcat` / `tomcat.service` | `tomcat10` / `tomcat10.service` | **`tomcat11` / `tomcat11.service`** (10 also present; newest wins) | **not packaged** (no EPEL) — N/A |
| PHP-FPM | `php-fpm` / `php-fpm.service` | `php8.3-fpm` / `php8.3-fpm.service` | **`php8.5-fpm` / `php8.5-fpm.service`** | versioned pkgs (`php8.2`–`php8.4`-fpm, newest wins) but **unversioned unit `php-fpm.service`** |
| PostgreSQL | `postgresql-server`, `postgresql.service` | `postgresql` meta → `postgresql@16-main.service` (cluster template) + `postgresql.service` umbrella | `postgresql` meta (cluster model; version per footprint) | versioned streams `postgresql15/16/17-server` (newest wins), unit `postgresql.service` |
| Redis-class | EL9 `redis`; **EL10: `valkey`** (`valkey.service`) | `redis-server` / `redis-server.service` | **`valkey`** (both offered; valkey per EL10 precedent) | **`valkey`** (redis6 also offered; valkey for row consistency) |
| MariaDB | `mariadb-server` / `mariadb.service` | same | same | versioned streams (`mariadb105`/`mariadb1011`-server, newest wins), unit `mariadb.service` |
| MySQL | EL9 only (`mysql-server`, `mysqld.service`); EL10 dropped it | `mysql-server` / `mysql.service` (wave-2 flip) | `mysql-server` / `mysql.service` | **not packaged** (community RPM only) — N/A |
| Caddy | via **EPEL** (`repos: [epel]` in the matrix cell) | universe | universe | **no EPEL support** — N/A |
| admin group | `wheel` | `sudo` | `sudo` | `wheel` |

## Paths

| Thing | EL / AL2023 | Ubuntu |
| --- | --- | --- |
| Apache config | `/etc/httpd/{conf,conf.d,conf.modules.d}` — drop-ins in `conf.d` | `/etc/apache2/{sites,mods,conf}-{available,enabled}` — `a2ensite`/`a2enmod` symlink model |
| Apache logs | `/var/log/httpd` | `/var/log/apache2` |
| PostgreSQL config | inside the data dir `/var/lib/pgsql/data/*.conf` (0700 — config edits are inherently ops or via ALTER SYSTEM) | **split out** to `/etc/postgresql/<ver>/main/{postgresql.conf,pg_hba.conf}` — config ACLs are grantable without touching the data dir |
| PostgreSQL data | `/var/lib/pgsql/data` | `/var/lib/postgresql/<ver>/main` |
| TLS certs/keys | `/etc/pki/tls/{certs,private}` | `/etc/ssl/{certs,private}` (`ssl-cert` group exists) |
| CA trust | `/etc/pki/ca-trust/source/anchors/` + `update-ca-trust` | `/usr/local/share/ca-certificates/` + `update-ca-certificates` |
| Vendor units | `/usr/lib/systemd/system` | `/usr/lib/systemd/system` and `/lib/systemd/system` (usr-merge symlink — footprints may show either) |

AL2023 follows the EL column throughout (Fedora-derived, dnf, systemd,
`/etc/pki` trust model).

## Behavior

- **apt auto-starts services on install** (policy-rc.d); dnf does not.
  Ubuntu footprints therefore include first-start side effects (state
  dirs, generated keys/certs like Apache's snakeoil pair) that EL captures
  lack. That's better evidence, not noise — but it means raw profiles are
  not comparable across distros line by line.
- Drift verification: `rpm -V` ↔ `dpkg --verify` (+ `debsums`).
- MAC: SELinux notes ↔ AppArmor notes. **AL2023 ships SELinux in
  permissive mode by default** — captures/verifies are honest about it in
  the VERIFIED stamp (`SELinux permissive`); the DAC/sudo/PAM surface the
  profiles manage behaves identically.
- **KVM image fidelity** (holy-qcow golden images): EL9/10, Ubuntu 24.04
  and AL2023 images are CIS Server L1 remediated (`/tmp` and `/var/tmp`
  noexec, firewalld/ufw on, auditd on, root umask 027). **Ubuntu 26.04 is
  not CIS-hardened yet** (no SSG content for 26.04) — its stamp says
  `no CIS hardening` until the image catches up.
- Host pam_group admin mapping: `wheel` ↔ `sudo` group.
- PEP 668: system pip needs `--break-system-packages` on Ubuntu 24.04+
  (tooling containers only — never on real hosts; the KVM harness uses
  venvs under `/opt`).
- EPEL: available and used on EL9/EL10 (`repos: [epel]` cells install
  `epel-release` before the re-baseline so it never pollutes footprints);
  **AL2023 has no EPEL compatibility** — absent packages there are N/A,
  not EPEL-fixable.
