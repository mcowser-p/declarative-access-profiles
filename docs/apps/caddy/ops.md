# caddy — lockdown runbook (ops)

Companion to the [dev guide](dev.md). Profiles:
`profiles/caddy/{almalinux-9,almalinux-10,ubuntu-24.04,ubuntu-26.04}-access.yml`
with their untouched `-raw.yml` siblings. amazonlinux-2023 is an explicit
matrix N/A — no EPEL support on AL2023 and caddy not in core repos — so no
artifacts exist for it. Role evaluation:
[role-evals/caddy](../../role-evals/caddy.md). Lifecycle mechanics:
[concepts/lifecycle.md](../../concepts/lifecycle.md).

## 1. Footprint summary (evidence)

From `footprints/<distro>/footprint-caddy.json` (schema 1.0, captured
2026-08-23 on the KVM golden-image substrate, treadmark 0.11.0):

| | alma9 | alma10 | ubuntu 24.04 | ubuntu 26.04 | al2023 |
| --- | --- | --- | --- | --- | --- |
| Package source | **EPEL** (`repos: [epel]`; repo enabled pre-baseline, so the window holds caddy + direct deps only) | **EPEL** (same) | universe | universe | N/A — no EPEL support on AL2023 and caddy not in core repos |
| Units installed | `caddy.service` + `caddy-api.service` (each counted twice — `/usr/lib` + `/lib` usr-merge alias) | same | same + enablement symlink for `caddy.service` only (apt auto-started it) | same as 24.04 | N/A |
| Unit user/caps | `User=caddy`, `AmbientCapabilities=CAP_NET_BIND_SERVICE`, `ExecStartPre=caddy validate` | same **+ `CAP_NET_ADMIN`** | `User=caddy`, `CAP_NET_BIND_SERVICE`, no validate, `ExecReload ... --force` | same as 24.04 | N/A |
| Accounts created | `caddy` (uid 993, system, nologin, home `/var/lib/caddy`) | `caddy` (uid 992, via a sysusers.d fragment) | `caddy` (uid 999/gid 987) **+ added to `www-data`** | `caddy` (uid 999/gid 986) + added to `www-data` | N/A |
| Key dirs | `/etc/caddy` root:root 0755 (`Caddyfile`, `Caddyfile.d/`); `/var/lib/caddy` caddy:caddy 0750 (empty); `/usr/share/caddy` (default site content) | same | `/etc/caddy` root:root (single `Caddyfile`); `/var/lib/caddy` caddy:caddy 0750 **with first-start state**: `.config/caddy/autosave.json` 0600, `.step` 0700, skel dotfiles; `/usr/share/caddy` | same as 24.04 | N/A |
| Dependency payload | `almalinux-logos-httpd` (test page + logos) | same + 484 vendored-Go license files under `/usr/share/licenses/caddy` | `libnss3-tools` — 29 NSS binaries (certutil etc.; why caddy wants them: §9) | same | N/A |
| Vendor sudoers shipped | none | none | none | none | N/A |

Two capture notes. **EL SELinux writes**: both EPEL installs wrote local
SELinux customizations — `file_contexts.local(.bin)` added,
`booleans.local` and `ports.local` written under
`/var/lib/selinux/targeted/active/`, policy recompiled (that rebuild
dominates the ~1.8k "modified" count). The scriptlet source isn't
attributable inside an install-window capture; treat the customizations as
package-managed state (§8). **Shared-VM noise**: the ubuntu-24.04 footprint
contains two `pg_internal.init` relcache files under
`/var/lib/postgresql` — postgresql (captured earlier in the same VM
session) regenerated them during caddy's window. They belong to postgres,
not caddy; nothing routes them into the profile.

Ubuntu's footprints include first-start side effects (apt auto-starts
services); EL captures do not. For caddy that difference is unusually
valuable evidence: first start shows the daemon writing its runtime state
`0700`/`0600` under `/var/lib/caddy` — the observation behind the §2
pam_group decision.

## 2. Raw → reviewed: the decisions

| Change | Tag | Why |
| --- | --- | --- |
| Drop `caddy-api` from services | REVIEW-DROP | The alternate config-by-API unit (`caddy run --resume`): config would live in `autosave.json` inside ungranted `/var/lib/caddy` (the file is visible in the Ubuntu first-start capture), bypassing the `/etc/caddy` ACL surface this profile is built on; conflicts with `caddy.service` over the same listeners; ships disabled. API-driven teams get a re-review, not a quiet grant. |
| Drop all `files_modify` (4 EL / 5 Ubuntu entries) | REVIEW-DROP | Vendor units (usr-merge aliases) + Ubuntu's enablement symlink; a unit-file write ACL is root-equivalent for that unit. Read-only-units profile. |
| Keep pam_group + `caddy` | REVIEW-KEEP | Webserver class: identity/read baseline + the content-dir group. Known side effect: `caddy` group-owns `/var/lib/caddy` 0750, so members can list its **top level** — but caddy creates runtime subdirs 0700/files 0600 (observed at Ubuntu first start), so the cert store below is closed. App-private group on Ubuntu too — no nginx-style shared-`www-data` caveat. |
| Keep `/etc/caddy` write | as captured | The class config ACL — `Caddyfile` + EL's `Caddyfile.d`. |
| **Drop `/var/lib/caddy` from folders_modify** | REVIEW-DROP | **The call of this review.** Caddy's home/storage is where automatic HTTPS keeps ACME account keys, site private keys, certificates and OCSP state. A team write ACL here = read/write on live TLS key material and the cert store. Data-dir rule: never in any grant list. Install state enforced via `ownership` instead. |
| Drop `/var/log/caddy` read (class default) | REVIEW-DROP | Not blind-added: the packages create no log dir and ship no logrotate/rsyslog fragment — caddy is journald-only at install, covered by the per-unit journalctl grants. Sites that configure file logs get the dir + grant at re-review (§10). |
| Keep `/var/lib/caddy` ownership caddy:caddy 0750 | as captured | Enforces install-time state; drift stays visible. |
| Add setgid content dir `/usr/share/caddy` root:caddy 2775 | REVIEW-ADD | The packaged default site root on **both** families (ships `index.html`; the stock Caddyfile serves it `[app-knowledge]`). Team writes content via the group; new files inherit it. The one intentional vendor-permission deviation — accept-list it (§8). |
| `caddy` → `www-data` membership (Ubuntu) | no action | Packaging gives the service account read of Debian-convention `/var/www` content. Service-side only; no team grant flows from it. |
| profile_name | no change | Exporter already emitted the distro-neutral `caddy` on all four — no REVIEW-CHANGE needed; the sudoers filename follows it. |

alma10's reviewed profile is identical to alma9's, and ubuntu-26.04's to
ubuntu-24.04's — stated in their headers with the capture-detail deltas
(alma10 adds `CAP_NET_ADMIN`, §11).

## 3. Access model for this app class

Webserver: **pam_group** (identity + content group at SSH login) +
**setgid content dir** + **config write ACL** (the team writes config; the
`caddy` account must not) + service control. See the
[access model](../../concepts/access-model.md) decision matrix. Caddy adds
one exclusion the matrix's database row usually owns: the service's
storage dir is treated like a data dir (never granted) because it holds
key material, not cache. The class's log-read ACL row is empty here —
journald-only at install (§10).

## 4. Apply

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/caddy/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
```

Artifacts to eyeball afterwards: `/etc/sudoers.d/caddy-rg-<host>-app-restricted`
(`visudo -cf` it), the `group.conf` line mapping the AD group to `caddy`,
`getfacl /etc/caddy`, the setgid content dir
(`stat -c '%a %U:%G' /usr/share/caddy` → `2775 root:caddy`), and
`/var/lib/caddy` still `0750 caddy:caddy` with **no** team ACL. Applying is
non-breaking while the team still holds app-full (group nesting).

## 5. Verify

`scripts/verify-profile.sh caddy <distro>` is the gate for the
`# VERIFIED:` header line — currently **pending** on all four profiles
(fresh 2026-08-23 review; run it before first production apply). On a live
host:

```bash
sudo -l -U <pilot>                          # exactly the scoped grants
sudo systemctl restart caddy                # allow
sudo journalctl -e -u caddy                 # allow (granted spelling)
sudo systemctl start caddy-api              # DENY (deliberately ungranted)
sudo systemctl restart sshd                 # DENY
echo x | sudo tee /usr/lib/systemd/system/caddy.service   # DENY
touch /var/lib/caddy/.probe                 # DENY (closed storage)
# behavioral pam_group — FRESH ssh login:
id                                          # shows caddy
touch /usr/share/caddy/.probe && rm $_      # content write via group
```

A stale session is a false negative — pam_group is per-login.

## 6. Flip

Remove the team from `<hostname>-app_full` (restricted grants are already
live via nesting), `loginctl terminate-user <user>` per user,
`sss_cache -E`. Confirm on a fresh login: `id` shows no wheel/sudo, `sudo -l`
shows only the profile.

## 7. Revoke / tighten later

Three moments: edit the profile pre-apply; override at apply time
(`-e '{"declarative_access_local_groups": []}'` for ACL-only); or full
revoke with the same command + `--tags cleanup`. Cleanup removes the
sudoers file, group.conf lines, and ACLs (incl. defaults). It deliberately
leaves parent-directory traverse ACLs (shared across profiles) and **never
reverts ownership** — the setgid content dir stays until you re-chown it
deliberately.

## 8. Drift and patching

`rpm -V caddy` / `dpkg --verify caddy` will flag the setgid content dir —
that is reviewed, intentional drift: record
`/usr/share/caddy 2775 root:caddy` in the golden-baseline accept-list.
ACLs are invisible to rpm/dpkg verification. Package upgrades replace
files and shed file ACLs — and EPEL updates faster than distro core, so
expect this more often on EL than for core-repo apps: re-run playbook 5
after patching; it is idempotent. On EL the package also owns the local
SELinux customizations from §1 — after any policy rebuild/relabel work,
confirm caddy still starts and serves before handing the host back.
authselect runs can drop the pam_group line from `/etc/pam.d/sshd` —
re-run or use a custom authselect profile.

## 9. TLS: key ownership and rotation

Caddy is the inversion of the
[canonical split](../../concepts/tls-ssl.md#renewal-the-split-between-ops-and-the-team):
with **automatic HTTPS** it is its own ACME client, and key material is
owned by the **service account**, not root — ACME account keys, site keys,
certs and OCSP state live under `/var/lib/caddy` (`caddy:caddy 0750`,
runtime subdirs 0700) `[app-knowledge]`, which is why that dir is in no
grant list (§2). Renewal is fully in-process: caddy re-issues and swaps
certificates itself, no file drop, no reload, no ops step
`[app-knowledge]`. The team's only TLS surface is Caddyfile config + the
granted reload; expiry monitoring is `openssl s_client` against the
running listener (the store is closed even for reads).

Issuance paths, in order of preference:

1. **Public ACME / internal ACME CA**: keep automatic HTTPS. For an
   enterprise CA that speaks ACME (the
   [mcowser_p.acme_please](../../concepts/tls-ssl.md#automated-issuance-and-renewal)
   estate), point `acme_ca` (+ EAB keys if required) at the internal
   directory in the Caddyfile — caddy replaces the certbot half of
   acme_please for caddy-terminated sites; the deploy-hook half is moot
   (no reload needed). Firewall/HTTP-01/TLS-ALPN-01 reachability is ops.
2. **Static platform-issued cert** (`tls <cert> <key>`): caddy has **no
   root phase** — the packaged units run it as `caddy` from exec, so the
   nginx/httpd "root reads the key" pattern does not apply and the `caddy`
   user itself must read the key. Do **not** group-own the key to `caddy`:
   pam_group would make it team-readable. Place it in the platform key dir
   (`/etc/pki/tls/private` / `/etc/ssl/private`), root:root 0600, plus a
   **user-scoped ACL**: `setfacl -m u:caddy:r <key>` (and `x` on the dir).
   Rotation then follows the canonical split: platform places, team runs
   the granted `sudo systemctl reload caddy`.

The cert-admin opt-in profile (team owns cert dirs) is a non-pattern for
caddy: the store is the service's own and must stay closed.

Side note the §1 evidence raises: Ubuntu's `libnss3-tools` dependency
(certutil and friends) exists for caddy's **local CA** feature —
`caddy trust` installs its self-minted root into NSS trust stores for
`localhost` HTTPS `[app-knowledge]`. Unused under this model (public or
internal ACME above); if a team asks for local-CA HTTPS, that trust-store
write is ops work.

## 10. Logs

journalctl grants are per-unit scoping — never substitute
`systemd-journal` group membership (host-global journal read). A stock
install has **no file logs and no logrotate fragment** (§1 evidence:
neither family ships one), so there is nothing to pre-flip-test and no
`/var/log/caddy` grant exists.

When a team requests file access logs
(`log { output file /var/log/caddy/<site>.log }`), the change is an ops
re-review, not just a config edit: create `/var/log/caddy`
`caddy:caddy 0750`, add it to `declarative_access_folders_read`, re-apply
playbook 5, and re-run verify. Caddy **self-rotates** file logs by default
(size-based rolling, compressed archives)
`[app-knowledge]` — like the other
[self-rotating applications](../../concepts/logging.md#self-rotating-applications),
rolled files are created by the daemon, so the dir's default ACL keeps
them team-readable and logrotate's `create`-mask gotcha doesn't arise. If
a site disables rolling and adds a logrotate fragment instead, the
canonical pre-flip test applies: `logrotate -f` the fragment, then
`getfacl` the fresh file and look for `#effective:---`.

## 11. Known risks (from `risks[]`)

Every captured entry is `severity: high`, `kind: ambient_capabilities` —
the same fact seen through each unit file path (4 entries on EL via
usr-merge aliases; 5 on Ubuntu incl. the enablement symlink):

| Finding | Distros | Decision | Owner |
| --- | --- | --- | --- |
| `caddy.service` / `caddy-api.service` grant `CAP_NET_BIND_SERVICE` | all four | **Accept.** This is caddy's privilege *floor*, not creep: the capability lets it bind 80/443 with **no root phase at all** — strictly less privilege than the nginx/httpd root-master pattern. Units are read-only in this profile. | ops |
| alma10 units additionally grant `CAP_NET_ADMIN` | alma10 | **Accept, flagged.** EPEL10's unit choice; broader than binding needs (plausibly for QUIC/HTTP3 UDP buffer sizing `[app-knowledge]`). Candidate for a tightening drop-in (`AmbientCapabilities=CAP_NET_BIND_SERVICE` override) in the org hardening overlay — a platform change, outside this profile. | ops |
| Unauthenticated local **admin API** on `localhost:2019` `[app-knowledge]` — not in `risks[]` (runtime behavior, invisible at install) | all four | **Fix on multi-user hosts.** Any local user could POST a new config or GET the running one (inline secrets included), bypassing the config ACL. Options: `admin unix//run/caddy/admin.sock` (socket perms limit callers; the granted reload keeps working — `ExecReload` runs as `caddy`) or `admin off` (costs the reload verb; restart only). Accept as-is only where local shell == the team. | ops |
| `caddy` user in `www-data` (Ubuntu) | ubuntu 24.04/26.04 | **Accept.** Packaging convention; gives the service read of `/var/www` content only. No team grant flows from it. | ops |

## 12. Storage and growth

Install-time floor, summed from the `filesystem` block of each
`footprints/<distro>/footprint-caddy.json`. Caddy is a single static Go
binary, and the usr-merge alias makes every summed count include it twice —
real on-disk is roughly half the summed figure:

| | alma9 | alma10 | ubuntu 24.04 | ubuntu 26.04 |
| --- | --- | --- | --- | --- |
| Install floor (all added files, as summed) | **91.9 MB** | **105.9 MB** | **82.1 MB** | **82.7 MB** |
| Dominated by | `caddy` binary, 45.9 MB (×2 aliases) | `caddy` binary, 52.4 MB (×2) | `caddy` 38.8 MB (×2) + 29 NSS tool binaries | same |

Treat that as a **floor, not a forecast** — it answers "will it fit", never
"how fast will it fill"
([sizing](../../concepts/storage.md#sizing-the-footprint-is-a-floor-not-a-forecast)).
`/var/log` is excluded from footprints, so no log volume is priced in.

Growth drivers, worst first:

| Driver | Bounded? | Detail |
| --- | --- | --- |
| Content root `/usr/share/caddy` | **No** | Whatever the team writes. The unbounded path in a plain install. |
| `/var/lib/caddy` cert store | Yes, per site — **unless on-demand TLS** | Keys/certs/OCSP state scale with site count (small). `[app-knowledge]`: `on_demand_tls` without an `ask` gate lets *clients* mint per-hostname certs — attacker-influenced growth. Treat any on-demand config as a review item. The dir is closed to the team (§2), so they can neither see nor clear it — growth questions are ops. |
| File access logs (only if granted, §10) | Yes — caddy self-rolls by default `[app-knowledge]` | Verbose access logging still churns disk between rolls. |
| journal | Yes — journald `SystemMaxUse` | Stock caddy's only log sink (§10). |

**Separate volume: not warranted for a plain install** — a sub-110 MB
floor with a journal-only log sink fits anywhere. Provision one when team
content is large; mount it at the existing content root, never a new path
(the profile grants the old one). The content root is a granted path
(setgid `2775` ownership), so a mount silently revokes the team. Order:
mount → restore owner/mode (and EL SELinux label) → **re-apply playbook 5**
(§4) → `stat`/`getfacl` to confirm. Full procedure:
[separate volumes: when and where](../../concepts/storage.md#separate-volumes-when-and-where).

Retention reality: the journal is bounded by journald defaults; granted
file logs are bounded by caddy's own rolling. Neither is in any profile —
**retention changes are an ops request**, handled in a change window.
