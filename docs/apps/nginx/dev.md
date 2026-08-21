# nginx — your life after lockdown

You deployed nginx; you're now in `<hostname>-app_restricted`. This page is
everything you can still do, and how. What ops decided and why is in the
[ops runbook](ops.md); your grants come from the reviewed profile for your
distro ([alma9](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/nginx/almalinux-9-access.yml),
[alma10](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/nginx/almalinux-10-access.yml),
[ubuntu 24.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/nginx/ubuntu-24.04-access.yml)).

## 0. First command: `sudo -l`

`sudo -l` prints your exact granted command lines. sudo matches the
**whole command string, argument order included** — `journalctl -u nginx -e`
is a different string from the granted `journalctl -e -u nginx` and will
prompt for a password. Copy from `sudo -l` output, not from memory.

## 1. Your grants at a glance

| What | How it's granted | Example |
| --- | --- | --- |
| Service control on nginx | sudoers: `start stop restart reload status enable disable mask unmask`, bare and `.service` spellings | `sudo systemctl reload nginx` |
| Its journal | sudoers: `journalctl -u nginx`, `-e -u`, `-ef -u`, `--since -5m/-10m/-15m` variants (bare + `.service`) | `sudo journalctl -e -u nginx` |
| `daemon-reload` | sudoers (global — see §2) | `sudo systemctl daemon-reload` |
| Config: `/etc/nginx` | write **ACL** for your team group (+ default ACL for new files) | edit `conf.d/*.conf` |
| Content: `/usr/share/nginx/html` (EL) / `/var/www/html` (Ubuntu) | setgid dir owned `root:nginx` (Ubuntu: `root:www-data`) — you're in that group at login via pam_group | write files; they inherit the group |
| Logs: `/var/log/nginx` | read ACL + default ACL | `less /var/log/nginx/access.log` |
| Service group at login | pam_group: `nginx` (Ubuntu: `www-data`) — **next SSH login only**, SSH sessions only, not cron | `id` after a fresh login |

## 2. Administering your systemd unit

The full verb set is granted for `nginx.service`. Prefer
`sudo systemctl reload nginx` for config changes — nginx reloads
gracefully without dropping connections; `restart` drops them.
`daemon-reload` is in your list because unit changes need it; it is
host-global by design — running it is harmless but affects every unit's
metadata, not just yours.

There are no timers or quadlets in this profile.

## 3. Editing configuration

Drop-in discipline: never edit `nginx.conf` itself — put changes in
`/etc/nginx/conf.d/<intention>.conf`, one intention per file. Validate
before reloading:

```bash
sudo nginx -t        # if granted; otherwise nginx -t works as root only —
                     # check sudo -l, and request the grant if you need it
sudo systemctl reload nginx
```

If a write to `/etc/nginx` or the content dir fails: did you log in
**after** the profile was applied? pam_group membership is granted at
login. Then `getfacl <path>` — you should see your team group (config) or
the service group on the directory (content).

## 4. TLS / SSL administration

What you can touch: your TLS **config** (a `conf.d` drop-in with
`listen 443 ssl`, `ssl_certificate`, `ssl_certificate_key`) and the
granted **reload** to pick up new certificates.

What you can't: the private key directory — `/etc/pki/tls/private` (EL) /
`/etc/ssl/private` (Ubuntu) is root-only and deliberately in **no**
profile. nginx's master process reads the key as root at startup/reload,
so neither you nor the nginx account ever needs key read. Key placement
and rotation is platform work (or an automated agent like certbot); see
[TLS under the access model](../../concepts/tls-ssl.md).

Renewal flow: check expiry without privileges
(`openssl x509 -enddate -noout -in /etc/pki/tls/certs/<host>.crt`) →
platform drops the new pair → **you** run `sudo systemctl reload nginx`.
Always ops: first-time TLS module/config beyond your paths, new ports
below 1024, key permission changes.

## 5. Logs and log rotation

nginx writes files to `/var/log/nginx/{access,error}.log` (read via your
ACL — no sudo needed) and startup/exit messages to the journal (read via
the granted `journalctl` spellings, verbatim in `sudo -l`).

Rotated logs stay readable because the profile set a **default ACL** on
`/var/log/nginx` — tomorrow's `access.log` and the `.gz` archives inherit
your read grant. If a rotated file is ever unreadable, run `getfacl` on it
and look for `#effective:---` lines — that's the logrotate `create`-mode
mask interaction, explained in
[Logs & rotation](../../concepts/logging.md). `/etc/logrotate.d/nginx` is
outside your grant: retention or frequency changes are a request to ops.

## 6. Storage: what fills up, and what you can do about it

Two things grow here: `/var/log/nginx/{access,error}.log` — the package
ships `/etc/logrotate.d/nginx`, so rotation is already handled — and
whatever your team writes into the content root (`/usr/share/nginx/html`,
Ubuntu `/var/www/html`), which nothing trims but you.

You can *see* usage — `df -h`, and `du -sh` inside your granted paths. You
cannot *fix* a full disk: `mount`, `mkfs`, `/etc/fstab`, `chown` on a mount
point, and edits to `/etc/logrotate.d/nginx` or journald limits are all ops
work needing a change window. So hand ops a growth estimate early, not
during the outage.

If ops mounts a volume over a granted path (the content root or
`/var/log/nginx`), the mount **hides** the ACLs and the setgid bit
underneath it and your access disappears with no error — ops must re-apply
the profile. See
[the mount-hides-ACLs trap](../../concepts/storage.md#the-trap-a-mount-hides-the-acls-underneath-it).

## 7. Everything else you'll eventually need

- **Env files/secrets**: nginx has none by default; app secrets included
  via `conf.d` must not contain private keys — see
  [concepts/tls-ssl.md](../../concepts/tls-ssl.md).
- **Installing modules** (`nginx-mod-*`), package upgrades, new units:
  change window — ops re-adds you to `<hostname>-app_full`, you work, you
  hand over again.
- **A command is denied**: read the denial, run `sudo -l`, and if the need
  is real, request either the exact command grant or a change window.

## 8. Per-distro differences

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| Package / unit | `nginx` / `nginx.service` | `nginx` / `nginx.service` | `nginx` / `nginx.service` |
| Service account:group | `nginx:nginx` | `nginx:nginx` | `www-data:www-data` |
| Config root | `/etc/nginx` (+`conf.d`) | `/etc/nginx` (+`conf.d`) | `/etc/nginx` (`sites-available` + `sites-enabled` symlink model also works; `conf.d` is simpler) |
| Content root | `/usr/share/nginx/html` | `/usr/share/nginx/html` | `/var/www/html` |
| Log dir | `/var/log/nginx` | `/var/log/nginx` | `/var/log/nginx` |
| Validator | `nginx -t` | `nginx -t` | `nginx -t` |
| TLS paths | `/etc/pki/tls/{certs,private}` | `/etc/pki/tls/{certs,private}` | `/etc/ssl/{certs,private}` |
| pam_group group | `nginx` | `nginx` | `www-data` (shared with other Debian web services — see the profile's REVIEW-KEEP) |

## 9. Cheat sheet

```bash
sudo -l                                   # your exact grants — start here
sudo systemctl status nginx               # health
sudo journalctl -e -u nginx               # recent journal (granted spelling)
vi /etc/nginx/conf.d/mysite.conf          # config change (ACL)
sudo nginx -t && sudo systemctl reload nginx
less /var/log/nginx/error.log             # file logs (ACL, no sudo)
id                                        # confirm service group (fresh login)
```
