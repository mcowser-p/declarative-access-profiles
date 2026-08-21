# HAProxy — your life after lockdown

You deployed HAProxy; you're now in `<hostname>-app_restricted`. This page is
everything you can still do, and how. What ops decided and why is in the
[ops runbook](ops.md); your grants come from the reviewed profile for your
distro ([alma9](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/haproxy/almalinux-9-access.yml),
[alma10](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/haproxy/almalinux-10-access.yml),
[ubuntu 24.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/haproxy/ubuntu-24.04-access.yml)).

HAProxy is leaner than the web-server profiles you may have seen. It runs as
**root** (its workers drop to the `haproxy` user internally), serves **no
content**, and logs through **syslog** — so there is no content directory, no
`pam_group` into a service group, and no log-directory ACL. What you get is
service control, the journal, and a write ACL on `/etc/haproxy`. That is the
whole profile.

## 0. First command: `sudo -l`

`sudo -l` prints your exact granted command lines. sudo matches the
**whole command string, argument order included** — `journalctl -u haproxy -e`
is a different string from the granted `journalctl -e -u haproxy` and will
prompt for a password. Copy from `sudo -l` output, not from memory.

## 1. Your grants at a glance

| What | How it's granted | Example |
| --- | --- | --- |
| Service control on haproxy | sudoers: `start stop restart reload status enable disable mask unmask`, bare and `.service` spellings | `sudo systemctl reload haproxy` |
| Its journal | sudoers: `journalctl -u haproxy`, `-e -u`, `-ef -u`, `--since -5m/-10m/-15m` variants (bare + `.service`) | `sudo journalctl -e -u haproxy` |
| `daemon-reload` | sudoers (global — see §2) | `sudo systemctl daemon-reload` |
| Config: `/etc/haproxy` | write **ACL** for your team group (+ default ACL for new files) | edit `haproxy.cfg` / `conf.d/*.cfg` (EL) |
| Content | **none** — HAProxy is a proxy, it serves no content root | — |
| Service group at login | **none** — no `pam_group`; the `haproxy` group owns nothing you need (see §3) | — |
| App log files | **none by default** — HAProxy logs via syslog; see §5 | `sudo journalctl -e -u haproxy` |

Everything you can do with sudo is in those first three rows plus the config
ACL. If you need something outside them, that's the denied-command playbook in
§7.

## 2. Administering your systemd unit

The full verb set is granted for `haproxy.service`. Prefer
`sudo systemctl reload haproxy` for config changes: HAProxy runs in
master-worker mode (`-Ws`) and reloads by validating the new config and
signalling the workers, so a reload is **seamless** — in-flight connections
finish on the old workers while new ones use the new config. `restart` tears
the process down and drops connections; use it only when a reload can't apply
the change (rare — e.g. changing the master socket).

The unit's own `ExecReload` runs `haproxy -c` (a config check) *before*
signalling, so a `reload` with a broken config **fails safe**: the running
service keeps its old config and the reason is in the journal. Validate first
anyway (§3) so you see the error before you touch the service.

`daemon-reload` is in your list because unit changes need it; it is host-global
by design — running it is harmless but affects every unit's metadata, not just
yours. There are no timers or quadlets in this profile.

## 3. Editing configuration

Your write ACL covers `/etc/haproxy`. **Where** your config goes differs by
distro (§8):

- **EL (alma9/alma10):** the unit loads `haproxy.cfg` **and** everything in
  `/etc/haproxy/conf.d/` (`-f $CONFIG -f $CFGDIR`). Use drop-in discipline: put
  each change in `/etc/haproxy/conf.d/<intention>.cfg`, one intention per file,
  and leave the vendor `haproxy.cfg` alone. HAProxy concatenates all `-f` files,
  so section names must stay unique across them.
- **Ubuntu 24.04:** the unit loads **only** `haproxy.cfg` (no `conf.d`). Edits
  go in `haproxy.cfg` directly — keep them minimal and clearly fenced, because
  you are editing the packaged main file. (Routing Ubuntu to a `conf.d` dir
  means changing `$EXTRAOPTS` in `/etc/default/haproxy`, which is an ops change —
  see §7.)

Validate before you reload — **no sudo needed**, because your ACL lets you read
the config and `-c` only parses it (it does not bind ports):

```bash
haproxy -c -f /etc/haproxy/haproxy.cfg                       # Ubuntu
haproxy -c -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d  # EL
sudo systemctl reload haproxy
```

"Why did my write fail?" HAProxy's config grant is a **direct ACL on your AD
group**, not `pam_group`, so there's no "log in again" step for it — it works in
any session where you're in `<hostname>-app_restricted`. If a write is refused,
`getfacl /etc/haproxy` and confirm your team group has `rwx`; a `#effective:`
cap there means the directory mask is narrowing it (the same mask mechanic
[Logs & rotation](../../concepts/logging.md) describes for log files).

Why no service group at login? On stock HAProxy the `haproxy` group has no
members and owns nothing you'd touch — the config and state dir are both
`root:root`. `pam_group` into it would grant nothing, so the profile omits it.
The [access model](../../concepts/access-model.md) covers why bare service-group
membership is usually a no-op.

## 4. TLS / SSL administration

HAProxy terminates TLS by reading a **single PEM file that concatenates the
certificate, its chain, and the private key** — e.g.
`bind :443 ssl crt /etc/pki/tls/private/site.pem`. That one file *contains the
private key*, which changes the rules from the nginx/httpd case.

**Where the PEM lives matters.** Keep it in the platform key directory —
`/etc/pki/tls/private/` (EL) or `/etc/ssl/private/` (Ubuntu), `root:root 0600` —
and reference it by absolute path from your config. Do **not** put it under
`/etc/haproxy/certs`: that path is inside your config write ACL (§3), so a key
placed there would be readable and writable by your whole team. The private-key
directory is deliberately in **no** profile — see
[TLS under the access model](../../concepts/tls-ssl.md).

What you can touch: the TLS **config** (the `bind ... ssl crt ...` line, cipher
and `ssl-default-*` settings in `haproxy.cfg`/`conf.d`) and the granted
**reload** to pick up a rotated cert.

What you can't: the PEM/key file itself. HAProxy re-reads it on `reload`, so
rotation is the clean two-step the access model describes — **ops places** the
new PEM in the key directory, **you run** `sudo systemctl reload haproxy`
(seamless, §2). Check expiry any time, no privileges needed:

```bash
openssl x509 -enddate -noout -in /etc/pki/tls/private/site.pem   # cert half of the bundle
openssl s_client -connect <host>:443 -servername <host> </dev/null 2>/dev/null | openssl x509 -noout -dates
```

Always ops: first-time TLS enablement that installs packages, new listeners on
ports below 1024, and any change to key file ownership/permissions.

## 5. Logs and log rotation

HAProxy does **not** write its own log files — it emits to **syslog**, and where
that lands is a site decision:

- **Service health** (start, reload results, config-check failures, worker
  crashes) is in the **journal**. Read it with your granted spellings, verbatim
  from `sudo -l`:

  ```bash
  sudo journalctl -e -u haproxy       # recent
  sudo journalctl -ef -u haproxy      # follow live; Ctrl-C stops
  ```

- **Traffic/access logs** go wherever rsyslog routes HAProxy's syslog facility:
  - **Ubuntu 24.04:** the package ships `/etc/rsyslog.d/49-haproxy.conf`, which
    writes to the flat file **`/var/log/haproxy.log`**.
  - **EL (alma9/alma10):** the package ships **no** rsyslog fragment, so out of
    the box traffic logging is unconfigured — the journal is all you have until
    someone points `log` (in `haproxy.cfg`) at a syslog target and configures
    rsyslog.

The profile grants **no `/var/log` ACL** because there's no application log
directory to grant, and a flat-file ACL wouldn't survive rotation anyway (the
default-ACL trick that keeps rotated files readable, described in
[Logs & rotation](../../concepts/logging.md), needs a *directory* to inherit
from). If your site routes HAProxy to a dedicated log **dir**, ask ops to add
that dir to the profile's `folders_read` — then rotated files stay readable the
same way the concept page describes, and `/etc/logrotate.d/haproxy` retention
changes remain an ops request.

## 6. Storage: what fills up, and what you can do about it

HAProxy barely grows on disk — it proxies traffic, it doesn't store it. No data
directory, no content root; the only thing that accumulates is your **log
stream** (§5): the journal, plus on Ubuntu the flat file `/var/log/haproxy.log`
sitting on the root filesystem. A chatty `option httplog` on a busy frontend is
the one realistic way this app fills a disk.

You can **look** — `df -h` for the filesystem, `du -sh /etc/haproxy` or any
other path you were granted. You can't **fix**: `mount`, `mkfs`, `/etc/fstab`,
`chown` a mount point, and edits to `/etc/logrotate.d/haproxy` or journald limits
are all root-equivalent, in no profile, and each one is an ops change window —
ask early with a growth estimate, not at 3am.

One failure worth being able to name: if ops mounts a filesystem over a path you
hold an ACL on, your access disappears with **no error** — the ACL is on the
directory now hidden underneath, and ops has to re-apply the profile to bring it
back ([Storage & growth](../../concepts/storage.md)).

## 7. Everything else you'll eventually need

- **Env / daemon-flag files** — `/etc/sysconfig/haproxy` (`$OPTIONS`, EL) and
  `/etc/default/haproxy` (`$EXTRAOPTS`, Ubuntu) set daemon flags (extra `-f`
  includes, the master socket). They are `root:root` and **outside your grant**
  — changing them is an ops change. You rarely need to: put your config in
  `haproxy.cfg`/`conf.d`, which you own via ACL.
- **Secrets** — HAProxy secrets live inside the config it reads (the TLS PEM,
  discussed in §4; `userlist` password hashes; stick-table keys). Keep private
  key material out of `/etc/haproxy` per §4.
- **Installing packages, new listeners <1024, new units** — change window: ops
  re-adds you to `<hostname>-app_full`, you work, you hand over again.
- **A command is denied** — read the denial, run `sudo -l`, and if the need is
  real, request either the exact command grant or a change window.

## 8. Per-distro differences

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| Package / unit | `haproxy` / `haproxy.service` | `haproxy` / `haproxy.service` | `haproxy` / `haproxy.service` |
| Runs as | root (workers drop to `haproxy` via config) | root (same) | root (same) |
| Config root | `/etc/haproxy` | `/etc/haproxy` | `/etc/haproxy` |
| Drop-in dir | `/etc/haproxy/conf.d` (loaded via `$CFGDIR`) | `/etc/haproxy/conf.d` | **N/A on ubuntu — unit reads only `haproxy.cfg`; no `conf.d`** |
| Env file | `/etc/sysconfig/haproxy` (`$OPTIONS`) | `/etc/sysconfig/haproxy` | `/etc/default/haproxy` (`$EXTRAOPTS`) |
| Validator | `haproxy -c -f …` (no sudo) | `haproxy -c -f …` | `haproxy -c -f …` |
| Traffic log sink | **N/A by default — no rsyslog fragment shipped; journal only** | same | `/var/log/haproxy.log` (package rsyslog fragment) |
| TLS PEM (keep root-only) | `/etc/pki/tls/private/` | `/etc/pki/tls/private/` | `/etc/ssl/private/` |
| pam_group service group | **N/A — omitted; `haproxy` group grants nothing** | same | same |

## 9. Cheat sheet

```bash
sudo -l                                        # your exact grants — start here
sudo systemctl status haproxy                  # health
sudo journalctl -e -u haproxy                  # recent journal (granted spelling)
vi /etc/haproxy/conf.d/mysite.cfg              # config change on EL (ACL); Ubuntu: edit haproxy.cfg
haproxy -c -f /etc/haproxy/haproxy.cfg         # validate (no sudo)
sudo systemctl reload haproxy                  # seamless apply
openssl x509 -enddate -noout -in /etc/pki/tls/private/site.pem   # cert expiry (no sudo)
```
