# MySQL — your life after lockdown

You deployed MySQL; you're now in `<hostname>-app_restricted`. This page is
everything you can still do, and how. What ops decided and why is in the
[ops runbook](ops.md); your grants come from the reviewed profile for your
distro ([alma9](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/mysql/almalinux-9-access.yml),
[ubuntu 24.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/mysql/ubuntu-24.04-access.yml),
[ubuntu 26.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/mysql/ubuntu-26.04-access.yml)).
MySQL covers **AlmaLinux 9 and Ubuntu 24.04/26.04** in this library — alma10
and Amazon Linux 2023 are N/A (see §8). The prose below uses the EL spellings
(`mysqld`, `/etc/my.cnf.d`); on Ubuntu the unit is **`mysql`** and the drop-in
dir is **`/etc/mysql/mysql.conf.d`** — the §8 table maps every path.

The one thing to internalise up front: this is a **database** profile, and it is
deliberately **config-scoped**. You can control the service, edit config
drop-ins, and read logs — but you get **no filesystem access to the data
directory** (`/var/lib/mysql`) or its siblings, and no service-group membership.
That is not an oversight: the `mysql` group owns the raw table files, and reading
them from disk bypasses every `GRANT` the database enforces. Database
administration happens through the **SQL client**, not the filesystem. See
[the database exception](../../concepts/access-model.md) for the reasoning.

## 0. First command: `sudo -l`

`sudo -l` prints your exact granted command lines. sudo matches the
**whole command string, argument order included** — `journalctl -u mysqld -e`
is a different string from the granted `journalctl -e -u mysqld` and will
prompt for a password. Copy from `sudo -l` output, not from memory.

## 1. Your grants at a glance

| What | How it's granted | Example |
| --- | --- | --- |
| Service control on `mysqld` | sudoers: `start stop restart reload status enable disable mask unmask`, bare and `.service` spellings | `sudo systemctl restart mysqld` |
| Its journal | sudoers: `journalctl -u mysqld`, `-e -u`, `-ef -u`, `--since`/`--until` variants (bare + `.service`) | `sudo journalctl -e -u mysqld` |
| `daemon-reload` | sudoers (global — see §2) | `sudo systemctl daemon-reload` |
| Config drop-ins: `/etc/my.cnf.d` | write **ACL** for your team group (+ default ACL for new files) | edit `zz-tuning.cnf` |
| Logs: `/var/log/mysql` | read **ACL** + default ACL | `less /var/log/mysql/mysqld.log` |
| Data directory `/var/lib/mysql` (+ `mysql-files`, `mysql-keyring`) | **NOT granted** — by design (database class) | use the SQL client instead |
| Service group at login | **NOT granted** — no pam_group (database class) | — |

There is **no content directory** and **no pam_group** in this profile — those
are webserver-class mechanisms. Everything you touch is config, logs, or the
unit. Mind the unit-name trap: on EL the service is **`mysqld`**
(`mysqld.service`), on Ubuntu it is **`mysql`** (`mysql.service`) — and on
Ubuntu your config ACL is on `/etc/mysql/mysql.conf.d` instead of
`/etc/my.cnf.d` (§8). sudo grants the spelling for *your* distro only.

## 2. Administering your systemd unit

The full verb set is granted for `mysqld.service` (Ubuntu: `mysql.service`).
On EL there is also a `mysqld@.service` **template** for running extra named
instances — it is *not* in your grant (single-instance deployments don't use
it; standing up a second instance is a change-window task; Ubuntu ships no
template unit at all).

Reload vs restart, for THIS app: MySQL does **not** re-read `my.cnf` on
`systemctl reload` — a reload (SIGHUP) flushes/reopens logs but leaves server
variables as they were. **Config-file changes take effect on
`sudo systemctl restart mysqld`**, which is a brief outage (connections drop).
Many server variables are also changeable live from the SQL client — prefer that
where the variable supports it, and persist it so it survives the next restart:

```sql
SET GLOBAL max_connections = 300;         -- live, this session forward
SET PERSIST max_connections = 300;        -- live AND written to mysqld-auto.cnf
```

`SET PERSIST` writes `mysqld-auto.cnf` **inside the data directory** (which you
can't reach on disk), but it's written *by the server* on your behalf, so you
don't need filesystem access for it. `[app-knowledge]`

`daemon-reload` is in your list because unit changes need it; it is host-global
by design — running it is harmless but affects every unit's metadata, not just
yours. There are no timers or quadlets in this profile.

## 3. Editing configuration

Drop-in discipline: never edit the vendor main file `/etc/my.cnf` (it is just
`!includedir /etc/my.cnf.d`). Put changes in a drop-in under `/etc/my.cnf.d`,
**one intention per file**, and prefix with `zz-` so it is read last and wins
over the packaged `client.cnf` / `mysql-server.cnf`:

```bash
vi /etc/my.cnf.d/zz-tuning.cnf     # your write ACL covers this directory
```

Same discipline on Ubuntu, different tree: the main file is
`/etc/mysql/mysql.cnf` (reached via the `/etc/mysql/my.cnf` alternatives
symlink — don't edit any of that chain), your ACL is on
`/etc/mysql/mysql.conf.d`, and your drop-in sorts after the packaged
`mysqld.cnf` there. Everything else under `/etc/mysql` — including
`debian.cnf`, the root-only maintenance-credential file — is outside your
grant on purpose (see [ops §2](ops.md#2-raw-reviewed-the-decisions)).

Each file needs a section header (`[mysqld]` for server settings, `[client]` for
client defaults). Unlike MariaDB, MySQL 8 ships an **offline config check** —
use it before restarting:

```bash
mysqld --validate-config          # parses the merged config, starts nothing
                                  # (whether it needs sudo to run as the mysql
                                  # account is [needs-runtime-confirmation])
sudo systemctl restart mysqld     # apply — brief outage
sudo journalctl -e -u mysqld      # confirm it came back up (or read the error)
```

**"Why did my write fail?"** Run `getfacl /etc/my.cnf.d` — you should see your
team group with `rwx`. Unlike a web server's profile there is **no pam_group**
here, so a stale login is *not* the cause; ACLs apply immediately. If you're
editing `/etc/my.cnf` itself, that's the vendor main file — outside your grant on
purpose; put your change in a drop-in instead.

## 4. TLS / SSL administration

**MySQL 8 turns TLS on by default and generates its own certificates.** At its
first initialization MySQL auto-generates a self-signed CA plus server
certificate and key (via `mysql_ssl_rsa_setup`, shipped at
`/usr/bin/mysql_ssl_rsa_setup` — confirmed in the footprint) and drops them
**inside the data directory** as `ca.pem` / `server-cert.pem` / `server-key.pem`.
The ubuntu-26.04 capture proves it: apt auto-started the server and the full
set is right there in `/var/lib/mysql` — certs `0644`, keys `0600`, all
`mysql:mysql`. On alma9, dnf does not auto-start, so the data dir was still
empty at capture — the same files appear the first time the server
initializes. `[app-knowledge]`

What that means for you: the key lives in `/var/lib/mysql`, which this profile
never grants — exactly the PostgreSQL-on-EL situation. **Key rotation is ops.**

- **You can** point `ssl_ca` / `ssl_cert` / `ssl_key` at CA-signed files (a
  `[mysqld]` block in your `/etc/my.cnf.d` drop-in) when you want to replace the
  self-signed defaults, and run your granted `sudo systemctl restart mysqld` to
  pick them up.
- **You can't** read or place the key. And note the MySQL wrinkle to hand ops:
  `mysqld` reads `ssl_key` as the **`mysql`** service account (the unit runs
  `User=mysql`), not root — so ops must place any CA-signed key *readable by
  `mysql`* (`root:mysql 0640`) with the correct `mysqld_db_t`/`cert_t` SELinux
  label, never world-readable and never in your profile.

The doctrine (keys are root-owned and in no profile) and the cert/key paths
(EL `/etc/pki/tls/{certs,private}`, Ubuntu `/etc/ssl/{certs,private}`) are in
[TLS under the access model](../../concepts/tls-ssl.md). Checking expiry needs no
privileges:

```bash
openssl x509 -enddate -noout -in /etc/pki/tls/certs/<host>.crt   # Ubuntu: /etc/ssl/certs
```

Renewal flow: platform drops the new pair with the `mysql`-readable perms above →
**you** run `sudo systemctl restart mysqld` (MySQL has no graceful TLS reload;
the restart is the pickup, with a brief outage). Always ops: first-time
CA-signed TLS enablement, the key placement/permissions, and any listener/port
change.

## 5. Logs and log rotation

Two places, two mechanisms (the general pattern is in
[Logs & rotation](../../concepts/logging.md)):

- **The journal** — startup, shutdown, crash and (until `log-error` is
  redirected) the error stream go here. Read it with the granted `journalctl`
  spellings, verbatim in `sudo -l`: `sudo journalctl -e -u mysqld`,
  `-ef -u mysqld` to follow live.
- **The error-log file** — the packaged `/etc/my.cnf.d/mysql-server.cnf` points
  `log-error` at `/var/log/mysql/mysqld.log`, which you read directly via your
  log ACL, **no sudo**: `tail -f /var/log/mysql/mysqld.log`. Whether the server
  writes a file here or only to journald depends on the effective `log-error`
  setting `[needs-runtime-confirmation]`. On Ubuntu the file log is the
  packaged default: `mysqld.cnf` ships
  `log_error = /var/log/mysql/error.log` `[app-knowledge]`, so
  `tail -f /var/log/mysql/error.log` is the everyday read there.

One database-specific trap: the **general query log and slow query log** default
to `log_output=FILE` under the log dir on MySQL, but can be switched to
**tables** inside the data directory (`mysql.general_log`, `mysql.slow_log`).
Table-based logs are **not** reachable through your log ACL — the data dir isn't
granted — so read those with the SQL client (`SELECT * FROM mysql.slow_log`) or
keep `log_output=FILE` so they land in the granted log dir. `[app-knowledge]`

Rotated files stay readable because the profile sets a **default ACL** on
`/var/log/mysql` — tomorrow's log and the `.gz` archives inherit your read grant.
If a rotated file is ever unreadable, `getfacl` it and look for `#effective:---`
— that's the logrotate `create`-mode mask interaction, explained in
[Logs & rotation](../../concepts/logging.md). The rotation fragment —
`/etc/logrotate.d/mysqld` on EL, `/etc/logrotate.d/mysql-server` on Ubuntu — is
outside your grant: retention or frequency changes are a request to ops.

## 6. Storage: what fills up, and what you can do about it

Everything unbounded sits in the one place you can't see: `/var/lib/mysql`
holds the dataset **and** the binary logs, which no log rotation ever touches
— MySQL 8 has binary logging on by default and only
`binlog_expire_logs_seconds` (30 days out of the box) trims them.
`[app-knowledge]` Anything you export with `SELECT ... INTO OUTFILE` lands in
the equally ungranted `/var/lib/mysql-files`; your log dir is the small,
rotated part.

You can **see** usage — `df -h`, plus `du -sh` inside `/etc/my.cnf.d` and
`/var/log/mysql`. The data dir isn't measurable from disk, so size it in SQL
(`information_schema.TABLES`, `SHOW BINARY LOGS`); purging binlogs is
superuser SQL, so that too is an ops request. You can't `mount`, `mkfs`, edit
`/etc/fstab`, `chown` a mount point, or change `/etc/logrotate.d/mysqld` or
journald limits — all ops, all a change window, so raise growth early.

**Flag this to ops:** a volume mounted *over* a granted path (realistically
`/var/log/mysql`) **hides** the ACLs underneath it and your access disappears
with no error until ops re-applies the profile —
[the mount-hides-ACLs trap](../../concepts/storage.md#the-trap-a-mount-hides-the-acls-underneath-it),
sized and sequenced for MySQL in [ops §12](ops.md#12-storage-and-growth).

## 7. Everything else you'll eventually need

- **Credentials / secrets.** Your own SQL credentials belong in a per-user
  `~/.my.cnf` (mode `0600`), not in a shared drop-in under `/etc/my.cnf.d`. DB
  user management (`CREATE USER`, `GRANT`) is SQL, not filesystem. MySQL 8's
  first-init temporary root password is written to the (ungranted) error log at
  initialization; on a locked-down host that first-run bootstrap is an ops step.
- **The data directory** is off-limits by design; backups (`mysqldump` /
  `mysqlpump` / `mysqlsh` dump utilities), restores, and table inspection go
  through the SQL client / a DB connection, never `/var/lib/mysql`. The
  `mysql-files` (`secure_file_priv`) and `mysql-keyring` (encryption keys) dirs
  are likewise never granted.
- **Package upgrades, a bigger data volume, a second instance
  (`mysqld@.service`)**: change window — ops re-adds you to
  `<hostname>-app_full`, you work, you hand over again.
- **A command is denied**: read the denial, run `sudo -l`, and if the need is
  real, request either the exact command grant or a change window.

Denied on purpose (you will hit these):

```bash
sudo systemctl restart sshd                 # DENY — not your unit
sudo journalctl -e -u mysql                 # DENY on EL — granted spelling is -u mysqld
sudo journalctl -e -u mysqld                # DENY on Ubuntu — the trap inverts: granted is -u mysql
echo x | sudo tee /var/lib/mysql/probe      # DENY — data dir is never granted
cat /var/lib/mysql-keyring/*                 # DENY — encryption keyring, never granted
vi /etc/my.cnf                              # the vendor main file — use a drop-in
```

## 8. Per-distro differences

Two cells are N/A across every row: **alma10** — `mysql-server` dropped from
EL10, `mariadb` is the packaged option (see [mariadb](../mariadb/dev.md)) —
and **al2023** — `mysql` is not packaged in Amazon Linux 2023 (community RPM
only, out of scope).

| | alma9 | alma10 | ubuntu 24.04 | ubuntu 26.04 | al2023 |
| --- | --- | --- | --- | --- | --- |
| Package | `mysql-server` (MySQL 8.0) | N/A — see above | `mysql-server` (MySQL 8.0) | `mysql-server` | N/A — see above |
| Unit (**the grant spelling**) | `mysqld.service` (+ `mysqld@.service` template, not granted) | N/A | `mysql.service` (no template unit) | `mysql.service` (no template unit) | N/A |
| Service account:group | `mysql:mysql` | N/A | `mysql:mysql` | `mysql:mysql` | N/A |
| Config main file (do not edit) | `/etc/my.cnf` | N/A | `/etc/mysql/mysql.cnf` (via the `/etc/mysql/my.cnf` alternatives symlink) | `/etc/mysql/mysql.cnf` (same alternatives chain) | N/A |
| Config drop-in dir (**your ACL**) | `/etc/my.cnf.d` | N/A | `/etc/mysql/mysql.conf.d` | `/etc/mysql/mysql.conf.d` | N/A |
| Root-only config outside your grant | — | N/A | `/etc/mysql/debian.cnf` (`root:root 0600`) + `debian-start` — the Debian maintenance layer, one level above your ACL | same (`debian.cnf` captured `root:root 0600`) | N/A |
| Log dir (**your ACL**) | `/var/log/mysql` (`mysqld.log`, if `log-error` targets a file) | N/A | `/var/log/mysql` (`error.log` — file log is the packaged default) | `/var/log/mysql` (`error.log`) | N/A |
| Config validator | `mysqld --validate-config` + restart + journal | N/A | same | same | N/A |
| TLS cert/key paths | auto-gen self-signed in `/var/lib/mysql` (never granted); CA-signed in `/etc/pki/tls/{certs,private}` | N/A | auto-gen in `/var/lib/mysql`; CA-signed in `/etc/ssl/{certs,private}` | same — the auto-gen set is captured in the footprint | N/A |
| MAC confinement | SELinux (policy module in the capture) | N/A | AppArmor — `/etc/apparmor.d/usr.sbin.mysqld` ships with the package | AppArmor — profile + `local/usr.sbin.mysqld` override stub | N/A |
| pam_group | N/A — database class grants no service-group membership | N/A | N/A — same | N/A — same | N/A |

If you need a MySQL-compatible database on AlmaLinux 10 or Amazon Linux 2023,
deploy **MariaDB** — the drop-in-compatible option this library covers there.

## 9. Cheat sheet

```bash
sudo -l                                     # your exact grants — start here
sudo systemctl status mysqld                # health (Ubuntu: mysql)
sudo journalctl -e -u mysqld                # recent journal (granted spelling; Ubuntu: -u mysql)
vi /etc/my.cnf.d/zz-tuning.cnf              # config drop-in (ACL; Ubuntu: /etc/mysql/mysql.conf.d)
mysqld --validate-config                    # sanity-check the merged config parses
sudo systemctl restart mysqld              # config changes need a RESTART, not reload
less /var/log/mysql/mysqld.log              # file logs (ACL, no sudo; Ubuntu: error.log)
mysql -u root -p                            # DB admin is SQL, not the filesystem
```
