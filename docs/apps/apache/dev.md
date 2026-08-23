# Apache HTTP Server — your life after lockdown

You deployed Apache (`httpd` on the EL family — AlmaLinux and Amazon Linux
2023 — `apache2` on Ubuntu); you're now in `<hostname>-app_restricted`. This
page is everything you can still do, and how. What ops decided and why is in
the [ops runbook](ops.md); your grants come from the reviewed profile for
your distro
([alma9](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/apache/almalinux-9-access.yml),
[alma10](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/apache/almalinux-10-access.yml),
[al2023](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/apache/amazonlinux-2023-access.yml),
[ubuntu 24.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/apache/ubuntu-24.04-access.yml),
[ubuntu 26.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/apache/ubuntu-26.04-access.yml)).

## 0. First command: `sudo -l`

`sudo -l` prints your exact granted command lines. sudo matches the
**whole command string, argument order included** —
`journalctl -u httpd -e` is a different string from the granted
`journalctl -e -u httpd` and will prompt for a password. Copy from
`sudo -l` output, not from memory.

## 1. Your grants at a glance

The unit is `httpd` on EL and `apache2` on Ubuntu — substitute yours.

| What | How it's granted | Example |
| --- | --- | --- |
| Service control | sudoers: `start stop restart reload status enable disable mask unmask`, bare and `.service` spellings | `sudo systemctl reload httpd` |
| Its journal | sudoers: `journalctl -u <unit>`, `-e -u`, `-ef -u`, `--since -5m/-10m/-15m` variants (bare + `.service`) | `sudo journalctl -e -u apache2` |
| `daemon-reload` | sudoers (global — see §2) | `sudo systemctl daemon-reload` |
| Config: `/etc/httpd` (EL) / `/etc/apache2` (Ubuntu) | write **ACL** for your team group (+ default ACL for new files) | edit `conf.d/*.conf` / `sites-available/*.conf` |
| Content: `/var/www/html` | setgid dir owned `root:apache` (Ubuntu: `root:www-data`) `2775` — you're in that group at login via pam_group | write files; they inherit the group |
| Logs: `/var/log/httpd` (EL) / `/var/log/apache2` (Ubuntu) | read ACL + default ACL | `less /var/log/httpd/error_log` |
| Service group at login | pam_group: `apache` (Ubuntu: `www-data`) — **next SSH login only**, SSH sessions only, not cron | `id` after a fresh login |

There is no grant for the unit files, the private-key directory, the
firewall, or `/var/lib/httpd` (`/var/lib/apache2`) — those are ops, by
design; see [§2 of the ops runbook](ops.md) for the raw→reviewed decisions.

## 2. Administering your systemd unit

The full verb set is granted for `httpd.service` (EL) / `apache2.service`
(Ubuntu). Prefer `sudo systemctl reload <unit>` for config and certificate
changes — Apache's reload is a **graceful** restart (`apachectl graceful`):
workers finish in-flight requests and new config is picked up without
dropping connections. `restart` drops them; use it only when a module load
or a change reload can't apply requires it.

Ubuntu 26.04 spelling trap: the package also installs `httpd.service` as a
**compat alias symlink** of `apache2.service`. The grant is spelled
`apache2` — `sudo systemctl reload httpd` is a different command string and
will be **denied**. Same unit, one granted name.

`daemon-reload` is in your list because unit changes need it; it is
host-global by design — running it is harmless but re-reads *every* unit's
metadata, not just yours.

There are no timers or quadlets in this profile. The cache cleaner
(`htcacheclean` on EL, `apache-htcacheclean` on Ubuntu) and Ubuntu's
one-shot `ssl-cert` generator were deliberately left out of the profile —
they're not the web server. If you turn on `mod_cache_disk`, ask ops to add
the cleaner unit back (see [ops §2](ops.md)).

## 3. Editing configuration

**Drop-in discipline: never edit the vendor main config.** One intention
per file.

- **EL** — leave `/etc/httpd/conf/httpd.conf` alone; put changes in
  `/etc/httpd/conf.d/<intention>.conf`. The package reads every `*.conf`
  in `conf.d` automatically.
- **Ubuntu** — leave `/etc/apache2/apache2.conf` alone. Site config goes in
  `/etc/apache2/sites-available/<name>.conf`; global snippets in
  `/etc/apache2/conf-available/<name>.conf`. Apache only reads the
  `*-enabled` directories, which hold **symlinks** to the `*-available`
  files (the `a2ensite`/`a2enmod` model).

  The normal enable helpers `a2ensite`/`a2enmod` still need `sudo` — they
  also write maintainer state under `/var/lib/apache2`, which is **not** in
  your profile. Because you hold the write ACL on the whole `/etc/apache2`
  tree, you can make the enable-symlink yourself without sudo instead:

  ```bash
  ln -s ../sites-available/mysite.conf /etc/apache2/sites-enabled/mysite.conf
  ```

Validate before reloading — the config tree is world-readable, so the
syntax check needs **no sudo**:

```bash
apachectl configtest          # EL also accepts: httpd -t
                              # Ubuntu also accepts: apache2ctl configtest
sudo systemctl reload httpd   # or apache2 — graceful
```

If a write to the config tree or the content dir fails: did you log in
**after** the profile was applied? pam_group membership is granted at
login. Then `getfacl <path>` — you should see your team group (config
tree) or the service group on the directory (content). The general "why
did my write fail" logic is in [the access model](../../concepts/access-model.md).

## 4. TLS / SSL administration

What you can touch: your TLS **config** and the granted **reload** to pick
up new certificates.

- **EL** — TLS lives in `/etc/httpd/conf.d/ssl.conf` (a `mod_ssl` drop-in)
  with `SSLCertificateFile` / `SSLCertificateKeyFile`. `mod_ssl` is a
  **separate package** and may not be installed — first-time TLS enablement
  is `dnf install mod_ssl`, which is an ops change window (it changes the
  install footprint), per the
  [always-ops escalations](../../concepts/tls-ssl.md#escalations-that-are-always-ops).
- **Ubuntu** — the `ssl` module ships with the package
  (`/etc/apache2/mods-available/ssl.conf`); enable it with `sudo a2enmod ssl`
  (or symlink it under your config ACL) and put `SSLCertificateFile` /
  `SSLCertificateKeyFile` in your `sites-available` vhost.

What you can't touch: the private-key directory —
`/etc/pki/tls/private` (EL) / `/etc/ssl/private` (Ubuntu) is root-only and
deliberately in **no** profile. Apache's parent process reads the key **as
root** at startup/reload before dropping privileges to `apache`/`www-data`,
so neither you nor the service account ever needs key read — this is the
cleanest case of [why key dirs stay out of profiles](../../concepts/tls-ssl.md#per-application-class-exceptions).

> Ubuntu note: the install auto-generated a **self-signed snakeoil** pair
> (`/etc/ssl/certs/ssl-cert-snakeoil.pem`, `/etc/ssl/private/ssl-cert-snakeoil.key`,
> `root:ssl-cert`). It exists only so TLS can start — replace it with a real
> CA-issued certificate before production; that swap is ops (key dir).

Renewal flow: check expiry without privileges
(`openssl x509 -enddate -noout -in /etc/pki/tls/certs/<host>.crt`) →
platform drops the new pair in the key dir → **you** run
`sudo systemctl reload <unit>`. The full split is in
[TLS under the access model](../../concepts/tls-ssl.md#renewal-the-split-between-ops-and-the-team).
Always ops: `mod_ssl` install (EL), new ports below 1024, key permission
changes.

## 5. Logs and log rotation

Apache writes files to `/var/log/httpd/{access_log,error_log}` (EL) /
`/var/log/apache2/{access.log,error.log,other_vhosts_access.log}` (Ubuntu)
— read via your ACL, **no sudo** — and startup/exit messages to the journal
(read via the granted `journalctl` spellings, verbatim in `sudo -l`).

Rotated logs stay readable because the profile set a **default ACL** on the
log directory — tomorrow's logs and the `.gz` archives inherit your read
grant. If a rotated file is ever unreadable, `getfacl` it and look for
`#effective:---` lines — that's the logrotate `create`-mode mask
interaction, explained in
[Logs & rotation](../../concepts/logging.md#the-mask-gotcha).
`/etc/logrotate.d/httpd` (EL) / `/etc/logrotate.d/apache2` (Ubuntu) is
outside your grant: retention or frequency changes are a request to ops.

## 6. Storage: what fills up, and what you can do about it

Two things grow here: **log files** in `/var/log/httpd` (Ubuntu:
`/var/log/apache2`), where the access log is usually the bulk of it
`[app-knowledge]`, and **content** under `/var/www/html`, which is as large
as whatever you write there. The journal is capped by default, so it isn't
what fills the disk.

You can see all of it without sudo — `df -h /var` for the filesystem, `du -sh`
inside your granted paths. You can't fix any of it: `mount`, `mkfs`,
`/etc/fstab`, `chown` on a mount point, and the retention knobs
(`/etc/logrotate.d/httpd` — Ubuntu `apache2` — and journald limits) are ops,
and each needs a change window. Raise it before you're full, not at 3am.

Worth knowing so you ask the right question: if ops mounts a volume over a
path you hold, **your ACLs disappear with no error** — they're on the
directory now hidden underneath, and ops has to re-apply the profile. That's
[the mount trap](../../concepts/storage.md#the-trap-a-mount-hides-the-acls-underneath-it),
not something you broke.

## 7. Everything else you'll eventually need

- **Env / tunables**: EL reads `/etc/sysconfig/httpd` (`$OPTIONS`); Ubuntu
  reads `/etc/apache2/envvars` (`APACHE_RUN_USER`, `APACHE_RUN_GROUP`, log
  dir). Both sit outside your config-tree ACL — changes there are ops.
- **Content**: write your site under `/var/www/html`; new files inherit the
  service group via the setgid bit, so the running server can read them.
- **CGI / suexec (EL)**: `/usr/sbin/suexec` runs CGI under a target user.
  It is privileged (see [ops §11](ops.md)); enabling suexec-based CGI is an
  ops conversation, not a config edit.
- **Installing modules** (`dnf install mod_*` / `a2enmod` of a not-yet-shipped
  module), package upgrades, new units: change window — ops re-adds you to
  `<hostname>-app_full`, you work, you hand over again.
- **A command is denied**: read the denial, run `sudo -l`, and if the need
  is real, request either the exact command grant or a change window.

## 8. Per-distro differences

Amazon Linux 2023 (`al2023`) is the EL shape throughout — same package,
units, account, and paths as alma9/10.

| | alma9 | alma10 | al2023 | ubuntu 24.04 | ubuntu 26.04 |
| --- | --- | --- | --- | --- | --- |
| Package / unit | `httpd` / `httpd.service` | `httpd` / `httpd.service` | `httpd` / `httpd.service` | `apache2` / `apache2.service` | `apache2` / `apache2.service` (+ `httpd.service` compat alias symlink — the grant is spelled `apache2`, see §2) |
| Service account:group | `apache:apache` | `apache:apache` | `apache:apache` | `www-data:www-data` | `www-data:www-data` |
| Config root | `/etc/httpd` (+`conf.d` drop-ins) | `/etc/httpd` (+`conf.d`) | `/etc/httpd` (+`conf.d`) | `/etc/apache2` (`sites-available` + `sites-enabled` symlink model) | `/etc/apache2` (same symlink model) |
| Drop-in dir | `/etc/httpd/conf.d/*.conf` | `/etc/httpd/conf.d/*.conf` | `/etc/httpd/conf.d/*.conf` | `/etc/apache2/{sites,conf}-available` + enable symlink | `/etc/apache2/{sites,conf}-available` + enable symlink |
| Content root | `/var/www/html` | `/var/www/html` | `/var/www/html` | `/var/www/html` | `/var/www/html` |
| Log dir | `/var/log/httpd` | `/var/log/httpd` | `/var/log/httpd` | `/var/log/apache2` | `/var/log/apache2` |
| Validator | `apachectl configtest` / `httpd -t` | `apachectl configtest` / `httpd -t` | `apachectl configtest` / `httpd -t` | `apache2ctl configtest` | `apache2ctl configtest` |
| TLS config | `/etc/httpd/conf.d/ssl.conf` (needs `mod_ssl` pkg) | same | same | `mods-available/ssl.conf` (`a2enmod ssl`) + vhost | same as 24.04 |
| TLS paths | `/etc/pki/tls/{certs,private}` | `/etc/pki/tls/{certs,private}` | `/etc/pki/tls/{certs,private}` | `/etc/ssl/{certs,private}` (`ssl-cert` group) | `/etc/ssl/{certs,private}` (`ssl-cert` group) |
| suexec (privileged CGI) | present (`/usr/sbin/suexec`) | present | present (same file-capability xattr — [ops §11](ops.md)) | **N/A on ubuntu 24.04 — `apache2-suexec-*` not installed by default** | **N/A on ubuntu 26.04 — same** |
| pam_group group | `apache` | `apache` | `apache` | `www-data` (shared with other Debian web services — see the profile's REVIEW-KEEP) | `www-data` (same caveat) |

## 9. Cheat sheet

```bash
sudo -l                                   # your exact grants — start here
sudo systemctl status httpd               # health (Ubuntu: apache2)
sudo journalctl -e -u httpd               # recent journal (granted spelling)
vi /etc/httpd/conf.d/mysite.conf          # config change (ACL); Ubuntu: sites-available
apachectl configtest && sudo systemctl reload httpd   # validate (no sudo) + graceful reload
less /var/log/httpd/error_log             # file logs (ACL, no sudo)
id                                        # confirm service group (fresh login)
```
