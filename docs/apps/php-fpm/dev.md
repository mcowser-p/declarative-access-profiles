# php-fpm — your life after lockdown

You deployed php-fpm; you're now in `<hostname>-app_restricted`. This page is
everything you can still do, and how. What ops decided and why is in the
[ops runbook](ops.md); your grants come from the reviewed profile for your
distro ([alma9](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/php-fpm/almalinux-9-access.yml),
[alma10](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/php-fpm/almalinux-10-access.yml),
[ubuntu 24.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/php-fpm/ubuntu-24.04-access.yml)).

One thing to get straight first: **php-fpm is the PHP engine, not the web
server.** A browser talks to nginx or Apache; the web server hands PHP
requests to php-fpm over a FastCGI socket. So your grant here is *the FPM
service and its pool config* — TLS, the document root, and the public
listener belong to the [nginx](../nginx/dev.md)/[apache](../apache/dev.md)
profile in front of it, not this one.

## 0. First command: `sudo -l`

`sudo -l` prints your exact granted command lines. sudo matches the **whole
command string, argument order included** — `journalctl -u php-fpm -e` is a
different string from the granted `journalctl -e -u php-fpm` and will prompt
for a password. Copy from `sudo -l` output, not from memory.

## 1. Your grants at a glance

Generated from the reviewed profile. EL unit/paths shown first; Ubuntu in
parentheses (see [§8](#8-per-distro-differences) for the full table).

| What | How it's granted | Example |
| --- | --- | --- |
| Service control on `php-fpm` (Ubuntu: `php8.3-fpm`) | sudoers: `start stop restart reload status enable disable mask unmask`, bare and `.service` spellings | `sudo systemctl reload php-fpm` |
| Its journal | sudoers: `journalctl -u php-fpm`, `-e -u`, `-ef -u`, `--since` variants (bare + `.service`) | `sudo journalctl -e -u php-fpm` |
| `daemon-reload` | sudoers (global — see §2) | `sudo systemctl daemon-reload` |
| Config: the FPM **pool dir** `/etc/php-fpm.d` (Ubuntu: `/etc/php/8.3/fpm/pool.d`) | write **ACL** for your team group (+ default ACL for new pools) | edit `www.conf`, add `myapp.conf` |
| Logs (EL): `/var/log/php-fpm` | read **ACL** + default ACL | `less /var/log/php-fpm/www-error.log` |
| Logs (Ubuntu): `/var/log/php8.3-fpm.log` | read **ACL** on the file (rotation caveat — §5) | `less /var/log/php8.3-fpm.log` |
| Service group at login | **not granted by default** — `apache`/`www-data` is an apply-time opt-in (§3, ops §3) | — |

There is **no pam_group** in this profile by default, and that's
deliberate: everything above works through sudoers and ACLs, none of which
depend on group membership or a fresh login. See §3 for when the opt-in
matters.

## 2. Administering your systemd unit

The full verb set is granted for `php-fpm.service` (Ubuntu:
`php8.3-fpm.service`). There are **no timers or quadlets** in this profile —
on Ubuntu the `phpsessionclean.timer` session garbage collector was left as
host housekeeping (ops [§2](ops.md#2-raw--reviewed-the-decisions)).

Reload vs restart, for THIS app:

- `sudo systemctl reload php-fpm` sends the master `SIGUSR2` — it re-reads
  `php.ini` and existing pool settings gracefully, finishing in-flight
  requests. Use it for most config changes. [app-knowledge]
- `sudo systemctl restart php-fpm` is required when you **add or remove a
  pool**, change a pool's `listen` socket, or change the master `user`/
  `group` — reload does not pick those up. It drops in-flight requests.
  [app-knowledge]

`daemon-reload` is in your list because edited unit files need it; it is
host-global by design (running it is harmless but re-reads every unit's
metadata, not just yours — see [the access model](../../concepts/access-model.md)).

## 3. Editing configuration

Your write ACL is on the **pool dir** only —`/etc/php-fpm.d` (Ubuntu:
`/etc/php/8.3/fpm/pool.d`). Drop-in discipline applies:

- **One pool per file.** Copy `www.conf` to `/etc/php-fpm.d/myapp.conf` for
  a new app rather than piling everything into `www.conf`.
- **Tune PHP inside the pool**, not in the shared `php.ini`. Your grant does
  **not** cover `/etc/php.ini` or the shared extension dir `/etc/php.d`
  (Ubuntu: `/etc/php/8.3/fpm/php.ini` and `mods-available`) — those are
  shared with the PHP CLI and are ops-managed. You don't need them: put
  `php_admin_value[memory_limit] = 256M`, `php_value[...]`, and `env[...]`
  lines directly in your pool file. [app-knowledge]

Validate before reloading:

```bash
php-fpm -t            # EL: syntax-checks the config (pool files are world-
                      # readable, so this runs as your user — no sudo needed)
php-fpm8.3 -t         # Ubuntu
sudo systemctl reload php-fpm
```

**"Why did my write fail?"** Config here is an **ACL**, not group
membership, so it does *not* depend on logging in after the profile applied.
Run `getfacl /etc/php-fpm.d` — you should see your team group with `rwx` and
a `default:` entry. If it's missing, the profile hasn't been applied to your
group yet (an ops question). The per-login caveat only bites if you took the
**pam_group opt-in** below.

**The pam_group opt-in.** By default you are *not* put into the `apache`
(Ubuntu: `www-data`) group, because php-fpm owns no content directory — the
document root your PHP executes from is the web server's, granted by the
[nginx](../nginx/dev.md)/[apache](../apache/dev.md) profile. On a co-located
LAMP/LEMP box you usually already have that group from the web-server
profile (that's how you write your app's `.php` files). If php-fpm is
standalone and you have a real need, ops can add it at apply time
(ops [§3](ops.md#3-access-model-for-this-app-class)) — remember pam_group is
granted **at SSH login**, so you'd need a fresh session for `id` to show it.

## 4. TLS / SSL administration

**php-fpm terminates no TLS.** It speaks FastCGI to the web server over a
local Unix socket (or `127.0.0.1:9000`); the certificate, private key, and
`listen 443 ssl` all live with nginx/Apache in front. So for a PHP site:

- Certificate and reload-to-pick-up-a-renewal are the **web server's**
  grant — see [nginx dev §4](../nginx/dev.md) / [apache dev §4](../apache/dev.md)
  and [TLS under the access model](../../concepts/tls-ssl.md). php-fpm needs
  no restart when the web server's cert rotates.
- **Private key dirs** (`/etc/pki/tls/private` EL, `/etc/ssl/private`
  Ubuntu) are root-only and in **no** profile — yours included. You never
  touch key material.
- If your PHP code makes **outbound** HTTPS calls and needs a private CA
  trusted, that's system CA-trust (`/etc/pki/ca-trust/source/anchors` +
  `update-ca-trust` on EL; `/usr/local/share/ca-certificates` +
  `update-ca-certificates` on Ubuntu) — an ops change, not a php-fpm config
  edit. See [tls-ssl.md](../../concepts/tls-ssl.md).

## 5. Logs and log rotation

php-fpm writes to two places:

- **The journal** — the master's start/stop/reload and fatal errors. Read
  it with the granted spellings (verbatim in `sudo -l`):
  `sudo journalctl -e -u php-fpm` (jump to newest),
  `sudo journalctl -ef -u php-fpm` (follow live). Ubuntu: `-u php8.3-fpm`.
- **Its own log files** — the FPM error log and per-pool
  `access.log`/`slowlog` when a pool enables them.
  - **EL:** these land under `/var/log/php-fpm/` and you read them via your
    directory ACL — no sudo (`less /var/log/php-fpm/www-error.log`). Rotated
    files stay readable because the profile set a **default ACL** on the
    dir; tomorrow's log and the `.gz` archives inherit your read grant. This
    is the canonical mechanism in [Logs & rotation](../../concepts/logging.md).
  - **Ubuntu:** the master log is the single file `/var/log/php8.3-fpm.log`,
    not a directory. Your read ACL covers that file and its renamed
    successors, but the **fresh** file logrotate creates after rotation gets
    no ACL (there's no default ACL on `/var/log` itself). So for durable FPM
    health, lean on `journalctl -u php8.3-fpm`; if you want default-ACL'd
    file logs, point a pool's `error_log`/`access.log` at a dedicated dir
    (e.g. `/var/log/php8.3-fpm/`) in your granted pool file and ask ops to
    add that dir to the profile. Details in [ops §10](ops.md#10-logs).

If a log is unexpectedly unreadable, `getfacl` it and look for
`#effective:---` — that's the logrotate `create`-mode mask interaction,
explained in [logging.md](../../concepts/logging.md).
`/etc/logrotate.d/php-fpm` (Ubuntu: `php8.3-fpm`) is **outside** your grant:
retention or frequency changes are a request to ops.

## 6. Storage: what fills up, and what you can do about it

php-fpm barely grows on its own: its logs are small and rotated, and it owns
no content directory — what your app accumulates lands in the **web server's
document root**, which is the [nginx](../nginx/dev.md)/[apache](../apache/dev.md)
grant, not this one. The php-fpm-shaped surprise is **session files**: on EL
nothing sweeps `/var/lib/php/session` on a schedule, so GC is only the
probabilistic `php_value[session.gc_*]` you set in your pool and a bad
`gc_probability` lets sessions pile up [app-knowledge]. Ubuntu ships
`phpsessionclean.timer` for it (host housekeeping — not yours).

You can **see** usage: `df -h`, and `du -sh` inside your granted paths (the
pool dir, `/var/log/php-fpm` on EL). You can't measure the session dir — it
isn't granted (EL `0770 root:apache`, Ubuntu `1733 root:root`, not even
listable) — so ask ops for that number. And you can't `mount`, `mkfs`, edit
`/etc/fstab`, `chown` a mount point, or change `/etc/logrotate.d/php-fpm` or
journald limits: all ops, all a change window.

**Flag this to ops:** a volume mounted *over* a path you were granted (here,
most plausibly `/var/log/php-fpm`) **hides** the ACLs underneath it and your
access disappears with no error — ops must re-apply the profile. See
[the mount-hides-ACLs trap](../../concepts/storage.md#the-trap-a-mount-hides-the-acls-underneath-it).

## 7. Everything else you'll eventually need

- **Env & secrets.** php-fpm has no env file of its own; per-pool
  `env[VAR] = value` and `php_admin_value[...]` lines live in your granted
  pool file. Keep secrets out of world-readable pool files where you can
  (pool files are `0644` — anyone on the host can read them) — prefer the
  application's own secret mechanism; never put a private key in a pool file
  (see [tls-ssl.md](../../concepts/tls-ssl.md)).
- **Session storage.** `/var/lib/php/session` (EL, `0770 root:apache`) /
  `/var/lib/php/sessions` (Ubuntu, `1733 root:root`) is written by the FPM
  workers, not you — it's **not** in your grant, and it holds live user
  session data. Change session behavior with `php_value[session.*]` in your
  pool, not by touching that directory.
- **Installing a PHP extension** (`dnf install php-<ext>` / `apt install
  php8.3-<ext>`), enabling a module in the shared `/etc/php.d`, or a **PHP
  version upgrade**: change window — ops re-adds you to `<hostname>-app_full`,
  you work, you hand over again (see [lifecycle](../../concepts/lifecycle.md)).
- **A command is denied.** Read the denial, run `sudo -l`, and if the need
  is real, request either the exact command grant or a change window.

## 8. Per-distro differences

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| Package | `php-fpm` | `php-fpm` | `php8.3-fpm` |
| Unit | `php-fpm.service` | `php-fpm.service` | `php8.3-fpm.service` |
| Runs as (pool) | `apache` | `apache` | `www-data` |
| Config root | `/etc/php-fpm.conf` + `/etc/php.ini` | same | `/etc/php/8.3/fpm/php-fpm.conf` + `php.ini` |
| Pool dir (**your ACL**) | `/etc/php-fpm.d` | `/etc/php-fpm.d` | `/etc/php/8.3/fpm/pool.d` |
| Log path (**your read**) | `/var/log/php-fpm/` (dir) | `/var/log/php-fpm/` (dir) | `/var/log/php8.3-fpm.log` (single file — §5 caveat) |
| Validator | `php-fpm -t` | `php-fpm -t` | `php-fpm8.3 -t` |
| Session GC timer | N/A on EL — session GC is `session.gc_probability` in `php.ini`, not a unit | N/A on EL — same | `phpsessionclean.timer` (host housekeeping — not in your profile) |
| TLS | N/A — terminated by the web server in front, not php-fpm | N/A — same | N/A — same |

## 9. Cheat sheet

```bash
sudo -l                                       # your exact grants — start here
sudo systemctl status php-fpm                 # health (Ubuntu: php8.3-fpm)
sudo journalctl -e -u php-fpm                  # recent journal (granted spelling)
vi /etc/php-fpm.d/myapp.conf                   # new pool (ACL; Ubuntu: .../pool.d/)
php-fpm -t && sudo systemctl reload php-fpm    # validate + graceful reload
sudo systemctl restart php-fpm                 # needed when adding/removing a pool
less /var/log/php-fpm/www-error.log            # file logs (EL: ACL, no sudo)
```
