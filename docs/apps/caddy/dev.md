# caddy — your life after lockdown

You deployed caddy; you're now in `<hostname>-app_restricted`. This page is
everything you can still do, and how. What ops decided and why is in the
[ops runbook](ops.md); your grants come from the reviewed profile for your
distro ([alma9](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/caddy/almalinux-9-access.yml),
[alma10](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/caddy/almalinux-10-access.yml),
[ubuntu 24.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/caddy/ubuntu-24.04-access.yml),
[ubuntu 26.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/caddy/ubuntu-26.04-access.yml)).
There is no Amazon Linux 2023 profile: caddy is N/A there — no EPEL support
on AL2023 and caddy is not in the core repos.

One caddy-specific thing colors this whole page: **caddy manages its own
TLS**. It issues and renews certificates itself and keeps them (with their
private keys) in its own storage, `/var/lib/caddy` — which is exactly why
that directory is in **no** grant list. See §4.

## 0. First command: `sudo -l`

`sudo -l` prints your exact granted command lines. sudo matches the
**whole command string, argument order included** — `journalctl -u caddy -e`
is a different string from the granted `journalctl -e -u caddy` and will
prompt for a password. Copy from `sudo -l` output, not from memory.

## 1. Your grants at a glance

| What | How it's granted | Example |
| --- | --- | --- |
| Service control on caddy | sudoers: `start stop restart reload status enable disable mask unmask`, bare and `.service` spellings | `sudo systemctl reload caddy` |
| Its journal | sudoers: `journalctl -u caddy`, `-e -u`, `-ef -u`, `--since -5m/-10m/-15m` variants (bare + `.service`) | `sudo journalctl -e -u caddy` |
| `daemon-reload` | sudoers (global — see §2) | `sudo systemctl daemon-reload` |
| Config: `/etc/caddy` | write **ACL** for your team group (+ default ACL for new files) | edit the `Caddyfile` |
| Content: `/usr/share/caddy` | setgid dir owned `root:caddy` — you're in that group at login via pam_group | write files; they inherit the group |
| Service group at login | pam_group: `caddy` — **next SSH login only**, SSH sessions only, not cron | `id` after a fresh login |

Two things you might expect are deliberately absent: there is **no log-file
grant** (a stock caddy writes only to the journal — see §5) and **no grant
on `/var/lib/caddy`** (caddy's certificate store — see §4). The
`caddy-api.service` unit that ships alongside `caddy.service` is also not
granted; the reasons are in the
[raw→reviewed decisions in ops §2](ops.md#2-raw-reviewed-the-decisions).

## 2. Administering your systemd unit

The full verb set is granted for `caddy.service`. Prefer
`sudo systemctl reload caddy` for config changes — the unit's reload runs
`caddy reload`, which applies the new config gracefully without dropping
connections; `restart` drops them. On EL, startup runs
`caddy validate` first (`ExecStartPre`), so a broken Caddyfile fails the
start instead of the running server. On Ubuntu the packaged reload passes
`--force` (applies even if the config file looks unchanged); there is no
startup validate, so run the validator yourself (§3) before reloading.
`daemon-reload` is in your list because unit changes need it; it is
host-global by design — running it is harmless but affects every unit's
metadata, not just yours.

`caddy-api.service` is installed but not enabled and **not in your
grants** — it runs caddy in config-by-API mode, which bypasses the
`/etc/caddy` config model this profile is built on. If your team wants
API-driven config, that's a profile re-review, not a workaround.

There are no timers or quadlets in this profile.

## 3. Editing configuration

Your config surface is `/etc/caddy` (write ACL). On EL, keep the drop-in
discipline: leave the vendor `Caddyfile` alone and put each site or change
in `/etc/caddy/Caddyfile.d/<intention>.caddyfile`, one intention per file —
the stock EPEL Caddyfile imports that directory `[app-knowledge]`. On
Ubuntu the package ships a single `Caddyfile` and no drop-in directory:
either edit it directly, or (better) create `/etc/caddy/sites/` inside
your granted tree and add one `import /etc/caddy/sites/*.caddyfile` line —
new files inherit your ACL via the default ACL.

Validate before reloading. The validator does not need sudo — your ACL
covers reading the config:

```bash
caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

(`caddy validate` may print a storage-access warning because
`/var/lib/caddy` is closed to you — that's expected and harmless for a
syntax check `[needs-runtime-confirmation]`.)

If a write to `/etc/caddy` or the content dir fails: did you log in
**after** the profile was applied? pam_group membership is granted at
login. Then `getfacl <path>` — you should see your team group (config) or
the `caddy` group on the directory (content).

## 4. TLS / SSL administration

Caddy inverts the usual TLS story: it is an ACME client as well as a web
server. Give a site a public hostname in the Caddyfile and caddy obtains
and renews the certificate itself — **automatic HTTPS**
`[app-knowledge]`.

What you can touch: the TLS-relevant **config** (site addresses, `tls`
directives, `email`) in your granted `/etc/caddy`, and the granted
`reload`/`restart` verbs.

What you can't: `/var/lib/caddy` — caddy's storage, where ACME account
keys, site private keys, certificates and OCSP state live. It is
`caddy:caddy 0750`, its runtime subdirectories are `0700`, and it is in
**no** profile. You never need it: renewal is fully in-process — caddy
rotates its own certificates and picks them up without a reload, so the
usual "platform drops files, you run the granted reload" flow doesn't even
apply to caddy-issued certs `[app-knowledge]`.

Expiry checking still needs no privileges — but ask the running server,
not the closed store:

```bash
openssl s_client -connect myservice.example.edu:443 \
  -servername myservice.example.edu </dev/null 2>/dev/null \
  | openssl x509 -noout -dates
```

If your site must use a **platform-issued certificate** (internal CA,
pinned cert), the shape changes: point the `tls <cert> <key>` directive at
the platform paths (`/etc/pki/tls/{certs,private}` on EL,
`/etc/ssl/{certs,private}` on Ubuntu) and run the granted reload after ops
rotates. One caddy-specific catch: caddy has **no root phase** — unlike
nginx/httpd, the `caddy` user itself must be able to read the key, so ops
places it with a user-scoped ACL rather than the usual root-only mode. How
ops handles that (and the internal-ACME alternative that keeps automatic
HTTPS) is [ops §9](ops.md#9-tls-key-ownership-and-rotation); the general
doctrine is [TLS under the access model](../../concepts/tls-ssl.md).

Always ops: first-time exposure of new ports/firewall openings for ACME
challenges, anything touching `/var/lib/caddy`, key permission changes.

## 5. Logs and log rotation

A stock caddy logs **only to the journal** — the packages create no
`/var/log/caddy`, and none is granted. Your granted `journalctl`
spellings (verbatim in `sudo -l`) are the whole story:

```bash
sudo journalctl -e -u caddy
sudo journalctl -ef -u caddy          # follow
sudo journalctl -u caddy --since -15m
```

Per-site **access logs** exist only if configured (`log { output file ... }`
in a site block) — and the target directory is not in your profile, so
file-based access logging is a request to ops, not a config edit: ops
creates the log dir, adds the read ACL, and re-reviews
([ops §10](ops.md#10-logs)). Once granted, rotated files stay readable
because default ACLs are inherited by new files; caddy **self-rotates**
its file logs by default `[app-knowledge]`, so the logrotate `create`-mode
mask gotcha only appears if your site switched rolling off in favor of
logrotate — the `getfacl` `#effective:` diagnostic and the canonical
explanation are in [Logs & rotation](../../concepts/logging.md).

## 6. Storage: what fills up, and what you can do about it

Three things grow here: whatever your team writes into the content root
`/usr/share/caddy` (nothing trims it but you); caddy's own storage
`/var/lib/caddy` (certificates and ACME state — small, grows with site
count, and closed to you, so a growth question there is an ops question);
and the journal (bounded by journald). File access logs, if ops ever
grants them, are bounded by caddy's default self-rotation
`[app-knowledge]`.

You can *see* usage — `df -h`, and `du -sh` inside your granted paths
(`du` on `/var/lib/caddy` will be refused — expected). You cannot *fix* a
full disk: mounts, `/etc/fstab`, journald limits are ops work in a change
window. If ops mounts a volume over a granted path, the mount **hides**
the ACLs and setgid bit underneath and your access disappears with no
error — ops must re-apply the profile; see
[the mount-hides-ACLs trap](../../concepts/storage.md#the-trap-a-mount-hides-the-acls-underneath-it).

## 7. Everything else you'll eventually need

- **Env files/secrets**: the packaged units set none (`EnvironmentFile` is
  empty on both families). Secrets referenced from the Caddyfile sit in
  your granted config tree — remember the admin API can serve the running
  config back out, so treat inline secrets as visible to any local user
  until ops locks the admin socket ([ops §11](ops.md#11-known-risks-from-risks)).
- **New caddy modules** (a rebuilt/`xcaddy` binary), package upgrades, new
  units, enabling `caddy-api`: change window — ops re-adds you to
  `<hostname>-app_full`, you work, you hand over again.
- **A command is denied**: read the denial, run `sudo -l`, and if the need
  is real, request either the exact command grant or a change window.

## 8. Per-distro differences

| | alma9 | alma10 | ubuntu 24.04 | ubuntu 26.04 | al2023 |
| --- | --- | --- | --- | --- | --- |
| Package / unit | `caddy` / `caddy.service` (EPEL) | `caddy` / `caddy.service` (EPEL) | `caddy` / `caddy.service` (universe) | `caddy` / `caddy.service` (universe) | N/A on al2023 — no EPEL support and caddy not in core repos |
| Service account:group | `caddy:caddy` | `caddy:caddy` | `caddy:caddy` (user also in `www-data`) | `caddy:caddy` (user also in `www-data`) | N/A (no package) |
| Config root | `/etc/caddy` + `Caddyfile.d` drop-ins | `/etc/caddy` + `Caddyfile.d` drop-ins | `/etc/caddy` (single `Caddyfile`) | `/etc/caddy` (single `Caddyfile`) | N/A (no package) |
| Content root | `/usr/share/caddy` | `/usr/share/caddy` | `/usr/share/caddy` | `/usr/share/caddy` | N/A (no package) |
| Log dir | none — journal only | none — journal only | none — journal only | none — journal only | N/A (no package) |
| Validator | `caddy validate --config /etc/caddy/Caddyfile` (also runs at start) | same as alma9 | `caddy validate --config /etc/caddy/Caddyfile` (manual only) | same as 24.04 | N/A (no package) |
| Reload behavior | `caddy reload` | `caddy reload` | `caddy reload --force` | `caddy reload --force` | N/A (no package) |
| TLS paths (static certs) | `/etc/pki/tls/{certs,private}` | `/etc/pki/tls/{certs,private}` | `/etc/ssl/{certs,private}` | `/etc/ssl/{certs,private}` | N/A (no package) |
| pam_group group | `caddy` | `caddy` | `caddy` (app-private — no shared `www-data` caveat) | `caddy` | N/A (no package) |

The EL packages come from **EPEL**, not the distro core repos, and their
units differ from Ubuntu's in small ways that matter to you: EL validates
config at start, Ubuntu doesn't; alma10's unit grants the service
`CAP_NET_ADMIN` on top of `CAP_NET_BIND_SERVICE` (an ops-accepted risk,
[ops §11](ops.md#11-known-risks-from-risks)). Ubuntu 26.04 is
layout-identical to 24.04, and alma10 to alma9 — the reviewed profiles say
so in their headers.

## 9. Cheat sheet

```bash
sudo -l                                   # your exact grants — start here
sudo systemctl status caddy               # health
sudo journalctl -e -u caddy               # recent journal (granted spelling)
vi /etc/caddy/Caddyfile.d/mysite.caddyfile   # EL config change (ACL); Ubuntu: vi /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
openssl s_client -connect localhost:443 </dev/null 2>/dev/null | openssl x509 -noout -dates
id                                        # confirm caddy group (fresh login)
```
