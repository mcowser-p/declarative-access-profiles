# redis — your life after lockdown

You deployed redis — or **valkey**, the drop-in fork: alma10, AL2023 and
ubuntu 26.04 package valkey instead, and everything here works the same with
`valkey` names; you're now in `<hostname>-app_restricted`. This page is
everything you can still do, and how. What ops decided and why is in the
[ops runbook](ops.md); your grants come from the reviewed profile for your distro
([alma9](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/redis/almalinux-9-access.yml),
[alma10](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/redis/almalinux-10-access.yml),
[AL2023](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/redis/amazonlinux-2023-access.yml),
[ubuntu 24.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/redis/ubuntu-24.04-access.yml),
[ubuntu 26.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/redis/ubuntu-26.04-access.yml)).

redis is locked down as a **cache**: you control the service, edit its config
file, and read its logs — but there is **no pam_group and no data-dir grant**.
The `redis` group owns `/var/lib/redis`, so being put in it would let you read
the persisted cache (`dump.rdb` / `appendonly.aof`) straight off disk, under
every redis password and ACL. Cache data is administered through `redis-cli`,
never the filesystem.

## 0. First command: `sudo -l`

`sudo -l` prints your exact granted command lines. sudo matches the **whole
command string, argument order included** — `journalctl -u redis -e` is a
different string from the granted `journalctl -e -u redis` and will prompt for a
password. Copy from `sudo -l` output, not from memory.

## 1. Your grants at a glance

Generated from the reviewed profile. Substitute your distro's unit/paths from §8
(`valkey` on alma10/AL2023, `redis-server` on ubuntu 24.04, `valkey-server` on
ubuntu 26.04).

| What | How it's granted | Example |
| --- | --- | --- |
| Service control | sudoers: `start stop restart reload status enable disable mask unmask`, bare and `.service` spellings | `sudo systemctl restart redis` |
| Its journal | sudoers: `journalctl -u redis`, `-e -u`, `-ef -u`, `--since -5m/-10m/-15m` variants (bare + `.service`) | `sudo journalctl -e -u redis` |
| `daemon-reload` | sudoers (global — see §2) | `sudo systemctl daemon-reload` |
| Config: `/etc/redis` (`/etc/valkey`) | write **ACL** for your team group (+ default ACL for files you `include`) | edit `redis.conf` / add an `include`d drop-in |
| Logs: `/var/log/redis` (`/var/log/valkey`) | read **ACL** + default ACL | `less /var/log/redis/redis-server.log` (Ubuntu); on EL, logs go to the journal |
| Service group at login | **N/A — no pam_group** (cache class; the service group owns the data dir) | — |
| Content / data dir | **N/A — never granted** (`/var/lib/redis` is off-limits) | use `redis-cli`, not the filesystem |

## 2. Administering your systemd unit

The full verb set is granted for your one unit (`redis` / `valkey` /
`redis-server` / `valkey-server`). Sentinel is **not** in your grant — see §7.

Reload vs restart matters more here than for a web server: **redis has no
zero-downtime config reload.** `systemctl reload` only nudges the running
process (log-file reopen); most `redis.conf` changes take effect **only on
restart**, and a restart drops all client connections and reloads state from
disk [app-knowledge]. Two clean paths:

- **Live, non-persistent:** `redis-cli CONFIG SET <param> <value>` changes many
  parameters instantly without a restart (needs the redis password/ACL, not
  sudo). `redis-cli CONFIG REWRITE` then writes the live value back into
  `redis.conf`.
- **Edit-then-restart:** change `redis.conf` via your ACL, then
  `sudo systemctl restart redis` — expect a brief outage and (unless persistence
  is on) an empty cache on the way back up.

`daemon-reload` is in your list because unit changes need it; it is host-global
by design — running it is harmless but affects every unit's metadata, not just
yours. There are no timers or quadlets in this profile.

## 3. Editing configuration

Your config-write ACL covers `/etc/redis` (`/etc/valkey`). redis has **no
`conf.d`/drop-in model** — it is one `redis.conf` plus optional `include`
directives. There is also **no offline validator** (`nginx -t` has no redis
equivalent): redis validates config by trying to start, and refuses to start on
a bad line, logging the reason [app-knowledge]. So the safe cycle is:

```bash
# trial a live-settable value first (no restart, no sudo — needs the redis auth):
redis-cli CONFIG SET maxmemory 512mb
# make it durable in the file (your ACL):
vi /etc/redis/redis.conf        # or an include'd drop-in you own
sudo systemctl restart redis
sudo systemctl status redis     # confirm it came back; read the journal on failure
```

If a config or log write fails: this profile grants config write by **ACL**, not
group membership, so there is no "log in again" step — but run
`getfacl /etc/redis` and confirm your team group has `rwx`. A write to
`/var/lib/redis` failing is **expected**: the data dir is deliberately not
granted.

## 4. TLS / SSL administration

redis speaks plaintext on 6379 by default; TLS is a separate listener you enable
in config (`tls-port`, `tls-cert-file`, `tls-key-file`, `tls-ca-cert-file`)
[app-knowledge]. What you can touch: that **TLS config**, in your granted
`/etc/redis` tree, plus the granted **restart** to pick up new material.

The redis key nuance — and it differs from nginx/httpd. redis-server runs as the
unprivileged **`redis` user from the very start** (the unit sets `User=redis`,
no root phase), so unlike nginx (whose root master reads the key), **redis reads
its TLS key as `redis`.** The key therefore has to be readable by the redis
service account — but still **not** by you. Placement stays platform/ops work:
they drop the key into the platform key dir and make it readable by `redis`
(group or ACL), never world- or team-readable. You never need key read; see
[TLS under the access model](../../concepts/tls-ssl.md).

Renewal flow: check expiry with no privileges
(`openssl x509 -enddate -noout -in /etc/pki/tls/certs/<host>.crt`) → platform
drops the new pair readable by `redis` → **you** run
`sudo systemctl restart redis` (redis has no graceful reload; expect the brief
outage from §2). Always ops: first-time TLS enablement, moving the port,
anything touching key file permissions.

## 5. Logs and log rotation

Two log worlds, split by distro — this is the one place redis and valkey differ
from the web-server pattern:

- **EL (alma9 redis; alma10/AL2023 valkey):** logs go to the **systemd
  journal** by default (`logfile` is unset in the shipped config, so output is
  captured by journald). Read it with the granted `sudo journalctl -e -u redis`
  (`-u valkey`) spellings, verbatim in `sudo -l`. Your `/var/log/redis`
  (`/var/log/valkey`) read ACL is in the profile for when an operator sets
  `logfile` to a path there — until then the dir may be empty
  [needs-runtime-confirmation].
- **Ubuntu (24.04 redis-server; 26.04 valkey-server):** logs go to a **file** —
  `/var/log/redis/redis-server.log` on 24.04, the configured `logfile` under
  `/var/log/valkey` on 26.04 — read via your ACL, no sudo:
  `tail -f /var/log/redis/redis-server.log`. Startup/crash messages also reach
  the journal.

Rotated logs stay readable because the profile set a **default ACL** on the log
directory — tomorrow's log and the `.gz` archives inherit your read grant. If a
rotated file is ever unreadable, `getfacl` it and look for `#effective:---`
lines — the logrotate `create`-mode mask interaction, explained in
[Logs & rotation](../../concepts/logging.md). `/etc/logrotate.d/redis`
(`/etc/logrotate.d/valkey`, `/etc/logrotate.d/redis-server`,
`/etc/logrotate.d/valkey-server`) is outside your grant: retention or frequency
changes are a request to ops.

## 6. Storage: what fills up, and what you can do about it

What grows here is **persistence**, and it lands in the one directory you can't
see into: `/var/lib/redis` (`/var/lib/valkey`). With RDB snapshots or AOF on,
what's on disk tracks the dataset in memory, and an AOF rewrite transiently needs
roughly **double** the AOF size [app-knowledge]; your lever is `maxmemory` from
§3, which caps both. With persistence off, redis is memory-only and writes
nothing — `redis-cli CONFIG GET save appendonly` tells you which you have
[needs-runtime-confirmation]. Logs are the slower burn: a file under
`/var/log/redis` (`/var/log/valkey`) on Ubuntu, the journal on EL (§5).

You can **look** — `df -h`, and `du -sh` inside your granted paths. You cannot
**fix**: `mount`, `mkfs`, `/etc/fstab`, `chown` on a mount point, and edits to
`/etc/logrotate.d/redis` or journald limits are all ops work needing a change
window. Hand ops a growth estimate early, not during the outage.

One failure worth being able to name: a filesystem mounted over a path you hold
an ACL on **hides** that ACL, and your access disappears with no error until ops
re-applies the profile
([the mount-hides-ACLs trap](../../concepts/storage.md#the-trap-a-mount-hides-the-acls-underneath-it),
sized and sequenced for redis in [ops §12](ops.md#12-storage-and-growth)).

## 7. Everything else you'll eventually need

- **Redis Sentinel** (`redis-sentinel` / `valkey-sentinel`): on the EL distros
  it is shipped by the package but **dropped from your profile** — the optional
  HA failover-monitor daemon, disabled by default and unused on a single-node
  cache. If your deployment actually runs Sentinel, that is a profile-review
  request (its `sentinel.conf` already sits inside your config ACL; only the
  service grant is missing). On ubuntu 24.04/26.04 the package ships no
  Sentinel at all — it is a separate package [app-knowledge], and installing it
  is a change window.
- **Env files / daemon options**: alma9 redis has none; alma10/AL2023 valkey
  reads an optional `/etc/sysconfig/valkey` (may not exist); ubuntu 24.04 ships
  `/etc/default/redis-server` and ubuntu 26.04 `/etc/default/valkey-server`
  (both `root:root`). None are in a granted path — changing `$DAEMON_ARGS` or
  `$OPTIONS` is ops.
- **Secrets**: the redis password (`requirepass` / an ACL `user`) lives inside
  `redis.conf` in your granted tree, so you can rotate it there — but keep it
  out of anything world-readable and prefer an `include`d file with tight
  perms. Never put private keys in config; see
  [concepts/tls-ssl.md](../../concepts/tls-ssl.md).
- **Package upgrades, new units, enabling Sentinel**: change window — ops
  re-adds you to `<hostname>-app_full`, you work, you hand over again.
- **A command is denied**: read the denial, run `sudo -l`, and if the need is
  real, request either the exact command grant or a change window. Expected
  denials: `sudo systemctl restart redis-sentinel` (not granted), any write
  under `/var/lib/redis` (data dir), editing the unit file.

## 8. Per-distro differences

| | alma9 | alma10 | AL2023 | ubuntu 24.04 | ubuntu 26.04 |
| --- | --- | --- | --- | --- | --- |
| Package / app | `redis` | **`valkey`** (redis fork; EL10 dropped redis) | **`valkey`** (AL2023 also ships `redis6`; this row packages valkey) | `redis-server` | **`valkey`** (26.04 also ships `redis-server`; this row packages valkey) |
| Unit | `redis.service` | `valkey.service` | `valkey.service` | `redis-server.service` (`redis.service` is a vendor alias — use the canonical name) | `valkey-server.service` (`valkey.service` is a vendor alias — use the canonical name) |
| Service account:group | `redis:redis` | `valkey:valkey` | `valkey:valkey` | `redis:redis` | `valkey:valkey` |
| Config root | `/etc/redis` (`redis.conf`) | `/etc/valkey` (`valkey.conf`) | `/etc/valkey` (`valkey.conf`) | `/etc/redis` (`redis.conf`) | `/etc/valkey` (`valkey.conf`) |
| Config perms | `redis:root 0750` (ACL needed) | `valkey:root 0750` (ACL needed) | `valkey:root 0750` (ACL needed) | `redis:redis 2770` (ACL granted anyway — see the profile's REVIEW-ADD) | `valkey:valkey 2770` (ACL granted anyway — same REVIEW-ADD) |
| Data dir (NOT granted) | `/var/lib/redis` | `/var/lib/valkey` | `/var/lib/valkey` | `/var/lib/redis` | `/var/lib/valkey` |
| Logs | journal by default; `/var/log/redis` if `logfile` set | journal by default; `/var/log/valkey` if `logfile` set | journal by default; `/var/log/valkey` if `logfile` set | **file**: `/var/log/redis/redis-server.log` + journal | **file** under `/var/log/valkey` + journal |
| Config validator | N/A — no offline validator; restart + check status/journal | N/A — same | N/A — same | N/A — same | N/A — same |
| Env file (ops, not granted) | N/A on alma9 — none shipped | `/etc/sysconfig/valkey` (optional) | `/etc/sysconfig/valkey` (optional) | `/etc/default/redis-server` | `/etc/default/valkey-server` |
| pam_group | N/A — cache class, no pam_group | N/A — same | N/A — same | N/A — same | N/A — same |
| Content dir | N/A — redis has none | N/A — same | N/A — same | N/A — same | N/A — same |
| TLS paths | `/etc/pki/tls/{certs,private}` (key readable by `redis`) | `/etc/pki/tls/{certs,private}` (key readable by `valkey`) | `/etc/pki/tls/{certs,private}` (key readable by `valkey`) | `/etc/ssl/{certs,private}` (key readable by `redis`) | `/etc/ssl/{certs,private}` (key readable by `valkey`) |

## 9. Cheat sheet

```bash
sudo -l                                    # your exact grants — start here
sudo systemctl status redis                # health (valkey / redis-server / valkey-server per distro)
sudo journalctl -e -u redis                # recent journal (granted spelling)
redis-cli CONFIG SET maxmemory 512mb       # trial a live value (redis auth, no sudo)
vi /etc/redis/redis.conf                    # durable config change (ACL)
sudo systemctl restart redis               # apply (brief outage — no graceful reload)
tail -f /var/log/redis/redis-server.log    # file logs on Ubuntu (ACL, no sudo)
openssl x509 -enddate -noout -in /etc/pki/tls/certs/<host>.crt   # cert expiry (no priv)
```
