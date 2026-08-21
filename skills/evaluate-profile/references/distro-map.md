# EL ↔ Ubuntu adaptation map (verified 2026-08)

The differences that change profiles and docs between AlmaLinux 9/10 and
Ubuntu 24.04. Every dev/ops doc's §7 distro table draws from here.

## Packages, units, accounts

| Thing | EL 9/10 | Ubuntu 24.04 |
| --- | --- | --- |
| Apache | pkg `httpd`, unit `httpd.service`, user/group `apache` | pkg `apache2`, unit `apache2.service`, user/group `www-data` |
| Tomcat | `tomcat` / `tomcat.service` / `tomcat` | `tomcat10` / `tomcat10.service` / `tomcat` |
| PHP-FPM | `php-fpm` / `php-fpm.service` | `php8.3-fpm` / `php8.3-fpm.service` |
| PostgreSQL | `postgresql-server`, `postgresql.service` | `postgresql` meta → `postgresql@16-main.service` (cluster template) + `postgresql.service` umbrella |
| Redis | EL9 `redis`; **EL10: `valkey`** (`valkey.service`) | `redis-server` / `redis-server.service` |
| MySQL | EL9 only (`mysql-server`, `mysqld.service`); EL10 dropped it | packaged, but out of wave 1 (mariadb covers) |
| admin group | `wheel` | `sudo` |

## Paths

| Thing | EL | Ubuntu |
| --- | --- | --- |
| Apache config | `/etc/httpd/{conf,conf.d,conf.modules.d}` — drop-ins in `conf.d` | `/etc/apache2/{sites,mods,conf}-{available,enabled}` — `a2ensite`/`a2enmod` symlink model |
| Apache logs | `/var/log/httpd` | `/var/log/apache2` |
| PostgreSQL config | inside the data dir `/var/lib/pgsql/data/*.conf` (0700 — config edits are inherently ops or via ALTER SYSTEM) | **split out** to `/etc/postgresql/16/main/{postgresql.conf,pg_hba.conf}` — config ACLs are grantable without touching the data dir |
| PostgreSQL data | `/var/lib/pgsql/data` | `/var/lib/postgresql/16/main` |
| TLS certs/keys | `/etc/pki/tls/{certs,private}` | `/etc/ssl/{certs,private}` (`ssl-cert` group exists) |
| CA trust | `/etc/pki/ca-trust/source/anchors/` + `update-ca-trust` | `/usr/local/share/ca-certificates/` + `update-ca-certificates` |
| Vendor units | `/usr/lib/systemd/system` | `/usr/lib/systemd/system` and `/lib/systemd/system` (usr-merge symlink — footprints may show either) |

## Behavior

- **apt auto-starts services on install** (policy-rc.d); dnf does not.
  Ubuntu footprints therefore include first-start side effects (state
  dirs, generated keys/certs like Apache's snakeoil pair) that EL captures
  lack. That's better evidence, not noise — but it means raw profiles are
  not comparable across distros line by line.
- Drift verification: `rpm -V` ↔ `dpkg --verify` (+ `debsums`).
- MAC: SELinux notes ↔ AppArmor notes.
- Host pam_group admin mapping: `wheel` ↔ `sudo` group.
- PEP 668: system pip needs `--break-system-packages` on Ubuntu 24.04
  (tooling containers only — never on real hosts).
