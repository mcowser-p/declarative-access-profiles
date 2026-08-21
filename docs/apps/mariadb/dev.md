# MariaDB — your life after lockdown

You deployed MariaDB; you're now in `<hostname>-app_restricted`. This page is
everything you can still do, and how. What ops decided and why is in the
[ops runbook](ops.md); your grants come from the reviewed profile for your
distro ([alma9](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/mariadb/almalinux-9-access.yml),
[alma10](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/mariadb/almalinux-10-access.yml),
[ubuntu 24.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/mariadb/ubuntu-24.04-access.yml)).

The one thing to internalise up front: this is a **database** profile, and it
is deliberately **config-scoped**. You can control the service, edit config
drop-ins, and read logs — but you get **no filesystem access to the data
directory** (`/var/lib/mysql`), and no service-group membership. That is not an
oversight: the `mysql` group owns the raw table files, and reading them from
disk bypasses every `GRANT` the database enforces. Database administration
happens through the **SQL client**, not the filesystem. See
[the database exception](../../concepts/access-model.md) for the reasoning.

## 0. First command: `sudo -l`

`sudo -l` prints your exact granted command lines. sudo matches the
**whole command string, argument order included** — `journalctl -u mariadb -e`
is a different string from the granted `journalctl -e -u mariadb` and will
prompt for a password. Copy from `sudo -l` output, not from memory.

## 1. Your grants at a glance

| What | How it's granted | Example |
| --- | --- | --- |
| Service control on `mariadb` | sudoers: `start stop restart reload status enable disable mask unmask`, bare and `.service` spellings | `sudo systemctl restart mariadb` |
| Its journal | sudoers: `journalctl -u mariadb`, `-e -u`, `-ef -u`, `--since`/`--until` variants (bare + `.service`) | `sudo journalctl -e -u mariadb` |
| `daemon-reload` | sudoers (global — see §2) | `sudo systemctl daemon-reload` |
| Config drop-ins: `/etc/my.cnf.d` (EL) / `/etc/mysql/mariadb.conf.d` (Ubuntu) | write **ACL** for your team group (+ default ACL for new files) | edit `zz-tuning.cnf` |
| Logs: `/var/log/mariadb` (EL only) | read **ACL** + default ACL | `less /var/log/mariadb/mariadb.log` |
| Logs on Ubuntu | journald only — granted `journalctl` spellings (no log dir exists) | `sudo journalctl -e -u mariadb` |
| Data directory `/var/lib/mysql` | **NOT granted** — by design (database class) | use the SQL client instead |
| Service group at login | **NOT granted** — no pam_group (database class) | — |

There is **no content directory** and **no pam_group** in this profile — those
are webserver-class mechanisms. Everything you touch is config, logs, or the
unit.

## 2. Administering your systemd unit

The full verb set is granted for `mariadb.service`. The service name to use is
**`mariadb`** — `mysql` and `mysqld` are compatibility aliases for the same
daemon and are *not* in your grant (see §8); use `mariadb` and the aliases are
irrelevant.

Reload vs restart, for THIS app: MariaDB does **not** re-read most of `my.cnf`
on `systemctl reload` — a reload (SIGHUP) flushes logs and re-opens files but
leaves server variables as they were. **Config-file changes take effect on
`sudo systemctl restart mariadb`**, which is a brief outage (connections drop).
Many server variables are also changeable live from the SQL client with
`SET GLOBAL …` (no restart, no outage) — prefer that for tunables that support
it, and put the same value in a drop-in so it survives the next restart.

`daemon-reload` is in your list because unit changes need it; it is host-global
by design — running it is harmless but affects every unit's metadata, not just
yours. There are no timers or quadlets in this profile.

## 3. Editing configuration

Drop-in discipline: never edit the vendor main file (`/etc/my.cnf` on EL,
`/etc/mysql/mariadb.cnf` on Ubuntu). Put changes in a drop-in, **one intention
per file**:

- **EL:** `/etc/my.cnf.d/zz-<intention>.cnf`
- **Ubuntu:** `/etc/mysql/mariadb.conf.d/zz-<intention>.cnf`

Your write ACL covers exactly that drop-in directory. Prefix with `zz-` so your
file is read last and wins over the packaged drop-ins. Each file needs a section
header (`[mariadbd]` for server settings, `[client]` for client defaults).

MariaDB has no clean offline validator like `nginx -t`. The honest cycle is:

```bash
mariadbd --print-defaults        # no sudo: prints the merged config it will parse
                                 # (a fatal parse error surfaces here)
sudo systemctl restart mariadb   # apply — brief outage
sudo journalctl -e -u mariadb    # confirm it came back up (or read the error)
```

If a write to the drop-in dir fails: run `getfacl` on the directory — you should
see your team group with `rwx`. If you're editing the wrong path (the vendor
main file, or `/etc/mysql/debian.cnf` on Ubuntu), that's outside your grant on
purpose — see §7.

## 4. TLS / SSL administration

**TLS is off by default.** MariaDB does **not** generate certificates at
install (we confirmed this from the capture — no `ca.pem`/`server-cert.pem`
appears even on the Ubuntu box where the daemon auto-started; see ops §9).
Enabling TLS is a config change plus ops placing key material.

What you can touch: your TLS **config** — an `ssl_ca` / `ssl_cert` / `ssl_key`
block in a `[mariadbd]` drop-in (in the drop-in dir from §3), and the granted
**restart** to pick it up.

What you can't: the private key. It lives root-owned in the platform key
directory (`/etc/pki/tls/private` on EL, `/etc/ssl/private` on Ubuntu),
deliberately in **no** profile. One MariaDB-specific wrinkle to know (and hand
to ops): unlike nginx/httpd — where *root* reads the key at startup — **mariadbd
reads `ssl_key` as the `mysql` service account**, so ops must place the key
*readable by `mysql`* (typically `root:mysql 0640`, or the `ssl-cert` group on
Ubuntu), never world-readable and never granted to your team. The doctrine and
the EL-vs-Ubuntu paths are in
[TLS under the access model](../../concepts/tls-ssl.md).

Renewal flow: check expiry without privileges
(`openssl x509 -enddate -noout -in /etc/pki/tls/certs/<host>.crt`) → platform
drops the new pair with the `mysql`-readable perms above → **you** run
`sudo systemctl restart mariadb`. Always ops: first-time TLS enablement, the key
placement/permissions, and any listener/port change.

## 5. Logs and log rotation

Two places, two mechanisms (the general pattern is in
[Logs & rotation](../../concepts/logging.md)):

- **The journal** — startup, shutdown, crash and (if unconfigured) the error
  stream go here. Read it with the granted `journalctl` spellings, verbatim in
  `sudo -l`: `sudo journalctl -e -u mariadb`, `-ef -u mariadb` to follow live.
- **The error-log file** — if `log_error` points at a file, it lands in
  `/var/log/mariadb/` (EL), which you read
  directly via your log ACL, **no sudo**:
  `tail -f /var/log/mariadb/mariadb.log`. Whether MariaDB writes a file here or
  only to the journal depends on the `log_error` setting
  `[needs-runtime-confirmation]`.

One database-specific trap: the **general query log and slow query log can be
stored as SQL tables** inside the data directory (the capture shows
`general_log.CSV` / `slow_log.CSV` under `/var/lib/mysql/mysql/`), not as files.
Table-based logs are **not** reachable through your log ACL — the data dir isn't
granted — so read them with the SQL client (`SELECT * FROM mysql.slow_log`) or
ask ops to switch `log_output=FILE` if you need them on disk.

Rotated files stay readable because the profile sets a **default ACL** on the
log directory — tomorrow's log and the `.gz` archives inherit your read grant.
If a rotated file is ever unreadable, `getfacl` it and look for `#effective:---`
— that's the logrotate `create`-mode mask interaction, explained in
[Logs & rotation](../../concepts/logging.md). `/etc/logrotate.d/mariadb` is
outside your grant: retention or frequency changes are a request to ops.

## 6. Storage: what fills up, and what you can do about it

What grows here is the **data directory**, and it's the one thing you can't see.
`/var/lib/mysql` holds the dataset plus — if anyone turns on `log_bin` — the
binlogs, which expire on `binlog_expire_logs_seconds` and are **never touched by
log rotation** `[app-knowledge]`. No grant of yours reaches that path, so
measure it from the SQL client (`information_schema.tables`), not with `du`.

You **can** watch the disk: `df -h`, and `du -sh` inside your granted paths (the
config drop-in dir; `/var/log/mariadb` on EL). You **cannot** `mount`, `mkfs`,
edit `/etc/fstab`, `chown` a mount point, or change `/etc/logrotate.d/mariadb`
or journald's limits — none of it is grantable, all of it is ops, all of it
needs a change window. Flag growth early; a full data volume at 3am is not
yours to fix.

One trap: a new mount over a granted path silently hides your ACLs, and your
access disappears with no error until ops re-applies the profile
([the mount trap](../../concepts/storage.md#the-trap-a-mount-hides-the-acls-underneath-it),
sized and sequenced for this app in [ops §12](ops.md#12-storage-and-growth)).

## 7. Everything else you'll eventually need

- **Credentials / secrets.** On Ubuntu, `/etc/mysql/debian.cnf` (`0600
  root:root`) holds the `debian-sys-maint` account password used by maintenance
  scripts — it is **deliberately outside your grant** (that's why the config ACL
  stops at the drop-in dir, not the whole `/etc/mysql` tree). Your own SQL
  credentials belong in a per-user `~/.my.cnf` (mode `0600`), not in a shared
  drop-in. DB user management (`CREATE USER`, `GRANT`) is SQL, not filesystem.
- **The data directory** is off-limits by design; backups (`mariadb-dump`),
  restores, and table inspection go through the SQL client / a DB connection,
  not `/var/lib/mysql`.
- **Package upgrades, new plugins, a bigger data volume**: change window — ops
  re-adds you to `<hostname>-app_full`, you work, you hand over again.
- **A command is denied**: read the denial, run `sudo -l`, and if the need is
  real, request either the exact command grant or a change window.

Denied on purpose (you will hit these):

```bash
sudo systemctl restart sshd                 # DENY — not your unit
sudo journalctl -e -u mysqld                # DENY — granted spelling is -u mariadb
echo x | sudo tee /var/lib/mysql/probe      # DENY — data dir is never granted
vi /etc/mysql/debian.cnf                     # DENY (Ubuntu) — credential file, no ACL
```

## 8. Per-distro differences

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| Package | `mariadb-server` | `mariadb-server` | `mariadb-server` |
| Unit (canonical) | `mariadb.service` | `mariadb.service` | `mariadb.service` |
| Unit aliases (not granted) | `mysql`, `mysqld` (Install.Alias) | `mysql`, `mysqld` (Install.Alias) | `mysql`, `mysqld` (Debian compat units) |
| Service account:group | `mysql:mysql` | `mysql:mysql` | `mysql:mysql` |
| Config main file (do not edit) | `/etc/my.cnf` | `/etc/my.cnf` | `/etc/mysql/mariadb.cnf` |
| Config drop-in dir (**your ACL**) | `/etc/my.cnf.d` | `/etc/my.cnf.d` | `/etc/mysql/mariadb.conf.d` |
| Log dir (**your ACL**) | `/var/log/mariadb` | `/var/log/mariadb` | N/A on ubuntu-24.04 — logs go to journald |
| Config validator | none built-in — `mariadbd --print-defaults` + restart + journal | same | same |
| TLS cert/key paths | `/etc/pki/tls/{certs,private}` | `/etc/pki/tls/{certs,private}` | `/etc/ssl/{certs,private}` |
| pam_group | N/A on all — database class grants no service-group membership | N/A | N/A |

## 9. Cheat sheet

```bash
sudo -l                                    # your exact grants — start here
sudo systemctl status mariadb              # health
sudo journalctl -e -u mariadb              # recent journal (granted spelling)
vi /etc/my.cnf.d/zz-tuning.cnf             # EL config drop-in (ACL)
vi /etc/mysql/mariadb.conf.d/zz-tuning.cnf # Ubuntu config drop-in (ACL)
mariadbd --print-defaults                  # sanity-check the merged config parses
sudo systemctl restart mariadb             # config changes need a RESTART, not reload
less /var/log/mariadb/mariadb.log          # file logs (ACL, no sudo)
mariadb -u root -p                         # DB admin is SQL, not the filesystem
```
