# PostgreSQL — your life after lockdown

You deployed PostgreSQL; you're now in `<hostname>-app_restricted`. This page
is everything you can still do, and how. What ops decided and why is in the
[ops runbook](ops.md); your grants come from the reviewed profile for your
distro ([alma9](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/postgresql/almalinux-9-access.yml),
[alma10](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/postgresql/almalinux-10-access.yml),
[ubuntu 24.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/postgresql/ubuntu-24.04-access.yml),
[ubuntu 26.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/postgresql/ubuntu-26.04-access.yml),
[al2023](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/postgresql/amazonlinux-2023-access.yml)).
Two families, five distros: Amazon Linux 2023 (package `postgresql17-server`)
behaves exactly like alma9/alma10 — everything below that says "EL" includes
it — and Ubuntu 26.04 is 24.04's model with PostgreSQL **18** in place of 16
(`postgresql@18-main`, `/etc/postgresql/18/main`).

The one thing to internalize first: PostgreSQL is a **database**, so this
profile is deliberately narrower than a web server's. You are **not** put
into the `postgres` group, because that group owns the raw data files and
membership would let you read and write the database *underneath* every SQL
`GRANT` the server enforces. Administration happens through the SQL client
and `systemctl`, not by editing files in the data directory. See
[the database exception](../../concepts/access-model.md) for the doctrine.

## 0. First command: `sudo -l`

`sudo -l` prints your exact granted command lines. sudo matches the **whole
command string, argument order included** — `journalctl -u postgresql -e` is
a different string from the granted `journalctl -e -u postgresql` and will
prompt for a password. Copy from `sudo -l` output, not from memory.

## 1. Your grants at a glance

| What | How it's granted | Example |
| --- | --- | --- |
| Service control | sudoers: `start stop restart reload status enable disable mask unmask`, bare and `.service` spellings, for `postgresql` (Ubuntu also the cluster unit: 24.04 `postgresql@16-main`, 26.04 `postgresql@18-main`) | `sudo systemctl reload postgresql` |
| Its journal | sudoers: `journalctl -u postgresql`, `-e -u`, `-ef -u`, `--since -5m/-10m/-15m` variants (bare + `.service`; Ubuntu also for the cluster unit) | `sudo journalctl -e -u postgresql@16-main` |
| `daemon-reload` | sudoers (global — see §2) | `sudo systemctl daemon-reload` |
| Config: `/etc/postgresql/16/main` on 24.04, `/etc/postgresql/18/main` on 26.04 (**Ubuntu only**) | write **ACL** for your team group (+ default ACL for new `conf.d` drop-ins) | edit `conf.d/*.conf`, `pg_hba.conf` |
| Config on EL (alma9, alma10, al2023) | **not a filesystem grant** — config lives in the 0700 data dir; you change it with `ALTER SYSTEM` (SQL) or it is an ops task (see §3) | `ALTER SYSTEM SET work_mem = '32MB';` |
| Logs: `/var/log/postgresql` (**Ubuntu only**) | read ACL + default ACL | `less /var/log/postgresql/postgresql-16-main.log` (26.04: `postgresql-18-main.log`) |
| Logs on EL | the journal only (file logs, if enabled, land in the closed data dir) | `sudo journalctl -e -u postgresql` |

There is **no** `pam_group` grant and **no** access to the data directory
(`/var/lib/pgsql` on EL, `/var/lib/postgresql/16/main` or `/18/main` on
Ubuntu) — by design, for a database.

## 2. Administering your systemd units

The full verb set is granted for the service. Two reload/restart facts that
are specific to PostgreSQL:

- **`reload` is a SIGHUP**, not a restart. It re-reads `postgresql.conf` and
  `pg_hba.conf` and applies every parameter that does not require a restart —
  with zero downtime and no dropped connections. Reach for it first:
  `sudo systemctl reload postgresql`.
- **`restart` drops every connection** and briefly takes the database down.
  Some parameters (`shared_buffers`, `max_connections`, `listen_addresses`,
  anything marked `postmaster` in `pg_settings.context`) only take effect on
  a restart — plan those for a maintenance window. `[app-knowledge]`

On **Ubuntu**, `postgresql.service` is an umbrella oneshot that starts/stops
*all* clusters on the host; the actual cluster is `postgresql@16-main.service`
(24.04) or `postgresql@18-main.service` (26.04). Both are granted — prefer
the cluster unit so you act only on your cluster
(`sudo systemctl restart postgresql@16-main`). On **EL** there is a single
`postgresql.service`. On 26.04 the host also has an `ssl-cert.service`
oneshot that (re)creates the system snakeoil TLS pair when the key is
absent — it is **not** in your profile (it is another package's unit, and
host-wide key material is never a team surface).

`daemon-reload` is in your list because unit changes need it; it is
host-global by design — running it is harmless but affects every unit's
metadata, not just yours. The backup-automation timers Debian ships
(`pg_dump@`, `pg_basebackup@`, …) are **not** in your profile; enabling
scheduled backups is an ops/change-window task (§7).

## 3. Editing configuration

This is where EL and Ubuntu genuinely differ, because the two packages put
the config in different places.

**Ubuntu — you have a config write ACL.** The config is split out of the
data directory into `/etc/postgresql/16/main` (26.04: `/etc/postgresql/18/main`
— substitute `18` for `16` in everything below), so you can edit it directly:

```bash
# drop-in discipline: one intention per file, never hand-edit the vendor
# postgresql.conf. Debian's postgresql.conf ends with include_dir 'conf.d'.
vi /etc/postgresql/16/main/conf.d/10-tuning.conf
sudo systemctl reload postgresql@16-main
```

`pg_hba.conf` (authentication rules) is in the same tree and covered by the
same ACL; changes to it also take effect on `reload`. There is **no cheap
offline validator** like `nginx -t`: PostgreSQL validates config at
reload/start. Reload, then check it took:

```sql
SELECT * FROM pg_file_settings WHERE error IS NOT NULL;  -- parse errors
SELECT name, setting, pending_restart FROM pg_settings WHERE pending_restart;
```

A reload that hits a bad value logs the error and keeps the *old* value
running — check the journal (`sudo journalctl -e -u postgresql@16-main`) or
`/var/log/postgresql/` after every reload.

**EL — config is inside the 0700 data directory, so you don't edit files.**
`postgresql.conf` and `pg_hba.conf` live under `/var/lib/pgsql/data`, which
is `0700 postgres:postgres` — a directory this profile does not (and must
not) let you enter. Change runtime parameters through SQL instead:

```sql
-- as a superuser in psql; writes postgresql.auto.conf inside the data dir
ALTER SYSTEM SET work_mem = '32MB';
SELECT pg_reload_conf();          -- same effect as systemctl reload
```

`pg_hba.conf` edits and anything `ALTER SYSTEM` can't set are an **ops task**
(ops edits as `postgres`, you run the granted `reload`). This is not a gap in
your grant — it is the database access model: the filesystem path into a
running database is exactly what the model keeps closed.

**"Why did my write fail?"** On Ubuntu, run `getfacl /etc/postgresql/16/main`
— you should see your team group with `rwx`. Unlike a web server's profile
there is no `pam_group` here, so a stale login is *not* the cause; ACLs apply
immediately. On EL, a write into the data dir is *supposed* to fail — use
SQL or file an ops request.

## 4. TLS / SSL administration

PostgreSQL is one of the two named exceptions in
[TLS under the access model](../../concepts/tls-ssl.md#per-application-class-exceptions):
**key rotation is always ops.** PostgreSQL requires `server.key` to be mode
`0600` and reads it from a place your profile cannot reach:

- **EL:** the server reads `server.crt` / `server.key` from *inside* the
  `0700` data dir (`/var/lib/pgsql/data/`). You cannot enter that directory,
  so you cannot place or rotate the key — ops does. `[app-knowledge]`
- **Ubuntu:** Debian ships TLS **on** by default, pointing at the system
  snakeoil pair (`/etc/ssl/certs/ssl-cert-snakeoil.pem` +
  `/etc/ssl/private/ssl-cert-snakeoil.key`). The `postgres` account can read
  the key only because the installer added it to the `ssl-cert` group
  (captured in the footprint) — the key stays `root:ssl-cert 0640` in
  `/etc/ssl/private`, and *you* are never in `ssl-cert`. Still ops-owned,
  still in no profile.

What you *can* do, on both: point `ssl_cert_file` / `ssl_key_file` at the
real (ops-placed) files — via `conf.d` on Ubuntu, via `ALTER SYSTEM` on EL —
and run your granted `reload` to pick up a rotated certificate. Checking
expiry needs no privileges:

```bash
openssl x509 -enddate -noout -in /etc/ssl/certs/<host>.crt
```

Renewal flow: ops (or an ACME agent) drops the new key material with its
`0600 root` / `0640 root:ssl-cert` permissions → **you** run
`sudo systemctl reload postgresql` (or `postgresql@16-main`). Always ops:
enabling TLS the first time on EL, any change to key file permissions, moving
the listener to a privileged port.

## 5. Logs and log rotation

Two log worlds, and they split by distro for PostgreSQL more than for most
apps — see [Logs & rotation](../../concepts/logging.md).

**The journal** carries startup/shutdown/crash messages on both distros; read
it with the granted `journalctl` spellings (verbatim in `sudo -l`). On Ubuntu
the interesting log is under the cluster unit:
`sudo journalctl -e -u postgresql@16-main` (26.04: `postgresql@18-main`).

**File logs:**

- **Ubuntu** writes detailed logs to
  `/var/log/postgresql/postgresql-16-main.log` (26.04: `postgresql-18-main.log`),
  granted by your read ACL — no
  sudo: `tail -f /var/log/postgresql/postgresql-16-main.log`. Rotated files
  stay readable because the profile set a **default ACL** on the directory.
- **EL** (al2023 included) has no `/var/log/postgresql`. With the default config the server
  logs to stderr, which systemd captures into the journal (so `journalctl` is
  your path). If a cluster later turns on the logging collector, its files
  land *inside the 0700 data dir* and are unreadable to you — that is an ops
  arrangement, not a grant you're missing.

**The PostgreSQL mask caveat.** PostgreSQL is the canonical self-rotating
app: when the logging collector rotates its own files, their mode comes from
`log_file_mode`, which defaults to `0600` `[needs-runtime-confirmation]`. At
`0600` the group-class bits are the ACL mask and cap your read grant to
nothing — `getfacl` shows `#effective:---`. On Ubuntu, where
`/etc/logrotate.d/postgresql-common` handles rotation instead, the same rule
applies to that fragment's `create` mode. Either way: if a fresh log is
unreadable, `getfacl` it and look for `#effective:---`
([the mask gotcha](../../concepts/logging.md#the-mask-gotcha)).
`/etc/logrotate.d/postgresql-common` is outside your grant — retention
changes are an ops request.

## 6. Storage: what fills up, and what you can do about it

PostgreSQL grows without a ceiling — the dataset, plus `pg_wal` beside it,
both inside the data dir you can't read. The 3am version is a **replication
slot nobody consumes**: it pins WAL segments forever, so the volume fills
while the dataset sits still. `[app-knowledge]` A base backup or `pg_dump`
needs headroom about equal to the dataset, all at once.

You **can** watch it — `df -h`, plus `du -sh` inside your granted paths
(Ubuntu's `/var/log/postgresql` and `/etc/postgresql/16/main` — `18/main` on
26.04; on EL the
profile grants no filesystem paths, so `df -h` is your whole view). You
**cannot** `mount`, `mkfs`, edit `/etc/fstab`, `chown` a mount point, or
touch `/etc/logrotate.d/postgresql-common` or journald's limits: none of it
is grantable, all of it is ops, all of it needs a change window. Raise
growth early — a full disk at 3am is not yours to fix.

When ops does add a volume: **a new mount over a granted path hides your
ACLs underneath it**, and your access vanishes with no error until ops
re-applies the profile
([the mount trap](../../concepts/storage.md#the-trap-a-mount-hides-the-acls-underneath-it),
sized and sequenced for this app in [ops §12](ops.md#12-storage-and-growth)).

## 7. Everything else you'll eventually need

- **Env / secrets.** On Ubuntu the cluster env file
  `/etc/postgresql/16/main/environment` is inside your config ACL. Database
  passwords are **not** files you manage — they live in the catalog
  (`ALTER ROLE ... PASSWORD`) and, for client auth, in a `~/.pgpass` you own.
  On EL the service's `PGDATA` is set in the unit itself, which you don't
  edit.
- **Scheduled backups.** Debian ships `pg_dump@`/`pg_basebackup@`/… timers;
  they are deliberately outside this profile. Turning on automated backups
  (or setting up `pg_dump`/WAL archiving on EL) is a change-window task so
  ops can review where dumps land and who can read them.
- **Bigger changes** (extensions that need packages, a major-version upgrade
  with `pg_upgrade`, new listeners): change window — ops re-adds you to
  `<hostname>-app_full`, you work, you hand over again.
- **A command is denied**: read the denial, run `sudo -l`, and if the need is
  real, request either the exact command grant or a change window.

## 8. Per-distro differences

| | alma9 | alma10 | ubuntu 24.04 | ubuntu 26.04 | al2023 |
| --- | --- | --- | --- | --- | --- |
| Package | `postgresql-server` | `postgresql-server` | `postgresql` (meta → `postgresql-16`) | `postgresql` (meta → `postgresql-18`) | `postgresql17-server` (versioned stream, unversioned paths) |
| Unit(s) | `postgresql.service` | `postgresql.service` | `postgresql.service` (umbrella) + `postgresql@16-main.service` (cluster) | `postgresql.service` (umbrella) + `postgresql@18-main.service` (cluster) | `postgresql.service` |
| Service account:group | `postgres:postgres` | `postgres:postgres` | `postgres:postgres` (also in `ssl-cert`) | `postgres:postgres` (also in `ssl-cert`) | `postgres:postgres` |
| Config location | inside data dir `/var/lib/pgsql/data/*.conf` (0700 — **not** granted) | same | split out to `/etc/postgresql/16/main` (**write ACL**) | split out to `/etc/postgresql/18/main` (**write ACL**) | same as alma9 |
| Config drop-in dir | N/A on alma9 — no on-disk config until `initdb`; use `ALTER SYSTEM` | N/A on alma10 — same | `/etc/postgresql/16/main/conf.d` | `/etc/postgresql/18/main/conf.d` | N/A on al2023 — same as alma9 |
| Data dir (never granted) | `/var/lib/pgsql/data` | `/var/lib/pgsql/data` | `/var/lib/postgresql/16/main` | `/var/lib/postgresql/18/main` | `/var/lib/pgsql/data` |
| Log dir | N/A on alma9 — journal only (collector logs into the 0700 data dir) | N/A on alma10 — journal only | `/var/log/postgresql` (**read ACL**) | `/var/log/postgresql` (**read ACL**) | N/A on al2023 — journal only |
| Config validator | N/A — validate via `pg_file_settings` after reload | N/A — same | N/A — same | N/A — same | N/A — same |
| TLS key location | inside `0700` data dir — ops only | same | `/etc/ssl/private` via `ssl-cert` group — ops only | `/etc/ssl/private` via `ssl-cert` group — ops only | inside `0700` data dir — ops only |

## 9. Cheat sheet

```bash
sudo -l                                        # your exact grants — start here
sudo systemctl status postgresql               # health (Ubuntu: @16-main / @18-main)
sudo systemctl reload postgresql               # apply config, no downtime (SIGHUP)
sudo journalctl -e -u postgresql               # recent journal (granted spelling)
# Ubuntu — config via ACL (24.04 shown; substitute 18 for 16 on 26.04):
vi /etc/postgresql/16/main/conf.d/10-tuning.conf && sudo systemctl reload postgresql@16-main
tail -f /var/log/postgresql/postgresql-16-main.log
# EL (alma9/alma10/al2023) — config via SQL:
#   psql -c "ALTER SYSTEM SET work_mem='32MB'; SELECT pg_reload_conf();"
```
