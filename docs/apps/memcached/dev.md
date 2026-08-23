# memcached — your life after lockdown

You deployed memcached; you're now in `<hostname>-app_restricted`. This page is
everything you can still do, and how. What ops decided and why is in the
[ops runbook](ops.md); your grants come from the reviewed profile for your distro
([alma9](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/memcached/almalinux-9-access.yml),
[alma10](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/memcached/almalinux-10-access.yml),
[AL2023](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/memcached/amazonlinux-2023-access.yml),
[ubuntu 24.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/memcached/ubuntu-24.04-access.yml),
[ubuntu 26.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/memcached/ubuntu-26.04-access.yml)).

memcached is locked down as a **cache**, and it is the most minimal profile in
the library: you control the service, edit its one config file, and read its logs
from the journal — and that is all. There is **no pam_group, no content dir, and
no data dir**. memcached is a pure in-memory cache: nothing it holds is on disk,
so there is nothing on disk to grant. Cache contents are administered over the
memcached protocol (`memcached-tool`, `nc`, a client library), never the
filesystem.

## 0. First command: `sudo -l`

`sudo -l` prints your exact granted command lines. sudo matches the **whole
command string, argument order included** — `journalctl -u memcached -e` is a
different string from the granted `journalctl -e -u memcached` and will prompt
for a password. Copy from `sudo -l` output, not from memory.

## 1. Your grants at a glance

Generated from the reviewed profile. Substitute your distro's config path from §8
(`/etc/sysconfig/memcached` on EL, `/etc/memcached.conf` on Ubuntu).

| What | How it's granted | Example |
| --- | --- | --- |
| Service control | sudoers: `start stop restart reload status enable disable mask unmask`, bare and `.service` spellings | `sudo systemctl restart memcached` |
| Its journal | sudoers: `journalctl -u memcached`, `-e -u`, `-ef -u`, `--since -5m/-10m/-15m` variants (bare + `.service`) | `sudo journalctl -e -u memcached` |
| `daemon-reload` | sudoers (global — see §2) | `sudo systemctl daemon-reload` |
| Config: the single tuning file | write **ACL** for your team group (file-scoped, no default ACL) | edit `/etc/sysconfig/memcached` (EL) / `/etc/memcached.conf` (Ubuntu) |
| Logs | granted `journalctl` spellings only — memcached logs to the **journal**, no file | `sudo journalctl -e -u memcached` |
| Service group at login | **N/A — no pam_group** (cache class; the service group owns nothing on disk) | — |
| Content / data dir | **N/A — memcached has neither** (in-memory cache) | use the memcached protocol, not the filesystem |

## 2. Administering your systemd unit

The full verb set is granted for the one unit, `memcached.service`. There are no
timers or quadlets in this profile.

Reload vs restart, memcached-style — and it is starker than any other app here:

- **`systemctl reload memcached` does nothing useful.** The vendor unit ships
  **no `ExecReload`**, so memcached has no live config reload at all
  `[app-knowledge]`. `reload` is in your sudoers list (the role grants the whole
  verb set uniformly), but the unit will reject it — don't rely on it.
- **Every config change needs a restart, and a restart empties the cache.**
  memcached holds everything in RAM with no persistence, so `systemctl restart`
  drops all client connections **and discards the entire cache** — the process
  comes back cold and clients see misses until it re-warms `[app-knowledge]`.
  Restart in a maintenance window or behind a client that tolerates a cold cache.

`daemon-reload` is in your list because unit changes need it; it is host-global
by design — running it is harmless but affects every unit's metadata, not just
yours.

## 3. Editing configuration

memcached has **no `conf.d`/drop-in model** — it is a single file, and that file
is not a config language but a list of daemon arguments:

- **EL family (alma9 / alma10 / AL2023)** (`/etc/sysconfig/memcached`): a shell
  env file read as the unit's `EnvironmentFile`. You set `PORT`, `USER`,
  `MAXCONN`, `CACHESIZE`, and free-form `OPTIONS` (e.g. `-l 127.0.0.1`, `-t 4`,
  `-I 2m`).
- **Ubuntu (24.04 / 26.04)** (`/etc/memcached.conf`): one memcached CLI flag per line
  (`-m 64`, `-p 11211`, `-u memcache`, `-l 127.0.0.1`, `-c 1024`), read by the
  unit's wrapper `/usr/share/memcached/scripts/systemd-memcached-wrapper`.

There is **no offline validator** (`nginx -t` has no memcached equivalent):
memcached validates its arguments by trying to start, and refuses to start on a
bad flag, logging the reason to the journal `[app-knowledge]`. The safe cycle:

```bash
vi /etc/sysconfig/memcached          # EL  — or /etc/memcached.conf on Ubuntu (your ACL)
sudo systemctl restart memcached     # expect an empty cache on the way back up (§2)
sudo systemctl status memcached      # confirm it came back
sudo journalctl -e -u memcached      # read the reason on failure
```

If a config write fails: this profile grants config write by **ACL**, not group
membership, so there is no "log in again" step (that is a pam_group thing, and
this profile has none). Run `getfacl /etc/sysconfig/memcached`
(`/etc/memcached.conf`) and confirm your team group has `rw-`. A write anywhere
under `/var/lib` failing is expected — memcached creates no data dir to write to.

## 4. TLS / SSL administration

memcached speaks its **plaintext protocol on 11211 by default; there is no TLS in
the shipped configuration** `[app-knowledge]`. memcached *can* do TLS (the `-Z` /
`--enable-ssl` flag with `-o ssl_chain_cert=…,ssl_key=…`), but only if the
packaged binary was built with OpenSSL support — confirm with
`memcached -h | grep -i ssl` before assuming it `[needs-runtime-confirmation]`.

What you can touch if TLS is in play: the TLS **arguments** in your granted
config file (add `-Z` and the `-o ssl_*` paths), plus the granted **restart** to
pick them up. What you can't: the private key directory
(`/etc/pki/tls/private` on EL, `/etc/ssl/private` on Ubuntu) is root-only and in
**no** profile. Because memcached drops to the `memcached`/`memcache` account
early, a TLS key must be made readable by that service account (group or ACL),
never by you — placement and permissions stay platform/ops work. See
[TLS under the access model](../../concepts/tls-ssl.md).

For most deployments the real "security config" is not TLS at all but the bind
address: memcached's `-l` flag is one of its only access controls, so binding to
`127.0.0.1` / a firewalled interface (in your config file) matters more here than
anywhere else — see §7.

## 5. Logs and log rotation

memcached writes **no log files** in its packaged configuration — it logs to
stderr, which systemd captures into the **journal**. Read it with the granted
spellings, verbatim in `sudo -l`:

```bash
sudo journalctl -e -u memcached       # recent
sudo journalctl -ef -u memcached      # follow
sudo journalctl --since -15m -u memcached
```

Because there is no log file, this profile has **no `/var/log` read ACL** — there
is nothing to grant — and the default-ACL / logrotate-`create`-mode mask
mechanics from [Logs & rotation](../../concepts/logging.md) simply don't apply
here. memcached ships **no `/etc/logrotate.d/memcached`** fragment either
(journald handles retention via its own vacuuming).

One caveat worth knowing: some **install roles turn file logging on** (both
geerlingguy.memcached and robertdebock.memcached template `logfile
/var/log/memcached.log` by default). If your host was built that way, memcached
writes a plain file at `/var/log/memcached.log` (root:root) that this profile
does **not** grant you and that has **no** logrotate — reading it or rotating it
is a profile-review request to ops. See the
[role evaluation §6b](../../role-evals/memcached.md).

## 6. Storage: what fills up, and what you can do about it

Nothing, on disk. memcached has no data dir, no content root and no log file
(§5): the cache is pure RAM, so what runs out here is **memory, not disk** —
and when it does, memcached evicts the oldest keys rather than growing
`[app-knowledge]`. That ceiling, `CACHESIZE` (EL) / `-m` (Ubuntu), lives in
your granted config file, so it is the one capacity knob you own outright;
raising it costs RAM and a cache-flushing restart (§2). Your journal output is
bounded by journald's own defaults.

The one exception: if an install role turned **file logging** on (§5),
`/var/log/memcached.log` grows unbounded with no logrotate — and it is not in
your grant, so you can neither read nor rotate it. Report it to ops.

You can **see** usage (`df -h`, `du -sh` on a granted path — here, just the
config file). You cannot **fix** it: `mount`, `mkfs`, `/etc/fstab`, `chown` on
a mount point, and journald limits are all root-equivalent, in no profile, and
each is an ops change window. And if ops ever mounts a volume over a path you
hold an ACL on, your access disappears with **no error** — ops must re-apply
the profile
([the mount-hides-ACLs trap](../../concepts/storage.md#the-trap-a-mount-hides-the-acls-underneath-it)).

## 7. Everything else you'll eventually need

- **Auth / secrets**: the classic memcached protocol has **no authentication**
  `[app-knowledge]`; SASL auth is an optional build/config feature, not on by
  default, and this profile manages no secret file. There is nothing secret in
  the config file to protect — which is exactly why the **bind address is the
  security boundary**. Keep `-l` pointed at localhost or a firewalled interface;
  widening it exposes an unauthenticated cache.
- **Env / options files**: EL reads `/etc/sysconfig/memcached` (that *is* your
  granted config file); Ubuntu also ships `/etc/default/memcached`, the vestigial
  SysV-init file — it is **not** read by the systemd wrapper and is **not** in
  your grant, so changing it does nothing under systemd. Ignore it.
- **Package upgrades, new units, enabling SASL/TLS builds**: change window — ops
  re-adds you to `<hostname>-app_full`, you work, you hand over again.
- **A command is denied**: read the denial, run `sudo -l`, and if the need is
  real, request either the exact command grant or a change window. Expected
  denials: editing the unit file (read-only units), any `sudo` outside the
  memcached service/journal grants, and reading `/var/log/memcached.log` if a
  role turned file logging on (§5).

## 8. Per-distro differences

| | alma9 | alma10 | AL2023 | ubuntu 24.04 | ubuntu 26.04 |
| --- | --- | --- | --- | --- | --- |
| Package / unit | `memcached` / `memcached.service` | same | same | same | same |
| Service account:group | `memcached:memcached` (uid/gid 992 as captured) | `memcached:memcached` (991) | `memcached:memcached` (992) | **`memcache:memcache`** (uid 112, gid 117 — note the name) | **`memcache:memcache`** (uid 104, gid 111) |
| Config file | `/etc/sysconfig/memcached` (shell env file) | `/etc/sysconfig/memcached` (shell env file) | `/etc/sysconfig/memcached` (shell env file) | `/etc/memcached.conf` (CLI-args file) | `/etc/memcached.conf` (CLI-args file) |
| Config mechanism | `EnvironmentFile` → `-u ${USER}` etc. in ExecStart | same | same | wrapper `systemd-memcached-wrapper /etc/memcached.conf` | same as 24.04 |
| Drop-in dir | N/A — single file, no `conf.d` | N/A — same | N/A — same | N/A — same | N/A — same |
| Content dir | N/A — memcached has none (in-memory) | N/A — same | N/A — same | N/A — same | N/A — same |
| Data dir | N/A — memcached has none (in-memory) | N/A — same | N/A — same | N/A — same | N/A — same |
| Log dir | N/A — journal only, no file | N/A — same | N/A — same | N/A — same | N/A — same |
| Validator | N/A — no offline validator; restart + check status/journal | N/A — same | N/A — same | N/A — same | N/A — same |
| pam_group | N/A — cache class, service group owns nothing | N/A — same | N/A — same | N/A — same | N/A — same |
| TLS paths (if built with TLS) | `/etc/pki/tls/{certs,private}` | `/etc/pki/tls/{certs,private}` | `/etc/pki/tls/{certs,private}` | `/etc/ssl/{certs,private}` | `/etc/ssl/{certs,private}` |

Ubuntu 26.04 is layout-identical to 24.04 (same wrapper, same config file, same
`memcache` account name); AL2023 follows the EL layout exactly — same
`memcached` account and `/etc/sysconfig/memcached` as alma9/alma10. The uid/gid
numbers are allocation-order artifacts of the golden image, not contract.

## 9. Cheat sheet

```bash
sudo -l                                     # your exact grants — start here
sudo systemctl status memcached             # health
sudo journalctl -e -u memcached             # recent journal (granted spelling)
vi /etc/sysconfig/memcached                 # config change (ACL); /etc/memcached.conf on Ubuntu
sudo systemctl restart memcached            # apply — WARNING: empties the cache (in-memory)
sudo systemctl status memcached             # confirm it came back
```
