# Tomcat — lockdown runbook (ops)

Companion to the [dev guide](dev.md). Profiles:
`profiles/tomcat/{almalinux-9,almalinux-10,ubuntu-24.04}-access.yml` with their
untouched `-raw.yml` siblings. Role evaluation:
[docs/role-evals/tomcat.md](../../role-evals/tomcat.md). Lifecycle mechanics:
[concepts/lifecycle.md](../../concepts/lifecycle.md).

Tomcat is the widest EL↔Ubuntu divergence in the library and the app where
**pam_group carries the primary grant**: the package ships the deploy tree
group-writable to `tomcat`, so the review's headline action is *adding* pam_group
(the EL raw omitted it) and *not* adding any ACL or setgid to the content dirs.

## 1. Footprint summary (evidence)

From `footprints/<distro>/footprint-tomcat.json` (schema 1.0, `install_time`,
captured 2026-08-09, cairn 0.10.0 feature branch; EL under SELinux enforcing).

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| files added / modified | 1305 / 228 | 1433 / 185 | 1918 / 48 |
| systemd unit entries | 4 | 4 | 3 |
| Distinct units | `tomcat.service`, `tomcat@.service` (each at `/usr/lib` + `/lib`, usr-merge) | same | `tomcat10.service` (at `/usr/lib`, `/lib`, + `multi-user.target.wants` symlink) |
| Account created | `tomcat` uid/gid **53**, home `/usr/share/tomcat`, `/sbin/nologin` | same | `tomcat` uid/gid **988**, home `/nonexistent`, `/usr/sbin/nologin` |
| cron jobs | 0 | 0 | 1 (`/etc/cron.daily/tomcat10` — logrotate) |
| `risks[]` | 0 | 0 | **3 (high)** — see §11 |
| Vendor sudoers | none | none | none |
| category counts | config 68, share_data 512, library 640, binary 70, state_dir 10, logrotate 1 | config 72, share_data 268, library 1024, binary 56, state_dir 8, logrotate 1 | config 60, share_data 1237, library 590, binary 14, state_dir 10, logrotate 1, cron_periodic 1, tmpfiles 1, sysusers 1 |

Key directories, captured owner:mode:

| Path (EL / Ubuntu) | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| Config root | `/etc/tomcat` `0755 root:tomcat` | same | `/etc/tomcat10` `0755 root:root` |
| Context dir | `/etc/tomcat/Catalina` `0775 root:tomcat` | same | `/etc/tomcat10/Catalina` `0775 root:tomcat` |
| Context (per-vhost) | `/etc/tomcat/Catalina/localhost` `0775 root:tomcat` | same | `/etc/tomcat10/Catalina/localhost` `0750 tomcat:tomcat` |
| CATALINA_HOME | `/usr/share/tomcat` `0775 root:tomcat` | same | `/usr/share/tomcat10` (root-owned tree) |
| CATALINA_BASE | `/var/lib/tomcat` `0755 root:tomcat` | same | `/var/lib/tomcat10` `0755 root:root` |
| Webapps (deploy) | `/var/lib/tomcat/webapps` `0775 root:tomcat` | same + `webapps-javaee` `0775 root:tomcat` | `/var/lib/tomcat10/webapps` `0775 tomcat:tomcat` |

The `group_access` block is the crux: the `tomcat` group is **writable** on
`{webapps, Catalina, Catalina/localhost, /usr/share/tomcat}` (EL) /
`{webapps, Catalina}` (Ubuntu) and **readable** on the whole config tree. That
is vendor-shipped group-write — the profile reuses it via pam_group rather than
laying down new ACLs (`references/review-rules.md` §7). `privilege.sudoers_files`
is empty on every distro (nothing to quote).

## 2. Raw → reviewed: the decisions

| Change | Distro | Tag | Why |
| --- | --- | --- | --- |
| **Add** `pam_group` + `local_groups: [tomcat]` | EL9, EL10 | REVIEW-ADD | app-server class; the raw omitted pam_group even though `group_access` shows `tomcat` owns the writable deploy tree. This is the primary grant — webapp deploy + context config through vendor group permissions, zero drift. |
| Keep `pam_group` + `local_groups: [tomcat]` | Ubuntu | REVIEW-KEEP | Exporter chose it correctly; `tomcat` is app-specific (not shared like `www-data`). |
| Drop all `files_modify` (4 / 4 / 3 entries) | all | REVIEW-DROP | Vendor unit files + the `tomcat@` template + apt's enablement symlink; a unit-file write ACL is root-equivalent for that unit. Read-only-units profile. |
| Keep `/etc/tomcat` in `folders_modify` (config ACL) | all | REVIEW-KEEP | Config files are root-owned, group-READ only; pam_group cannot write them. The ACL grants the *team* config write (server.xml, conf.d, the keystore) without chgrp-ing config to the service account. |
| Drop `/etc/.java`, `/etc/java*`, `/etc/jvm*` | all | REVIEW-DROP | JVM / update-alternatives config from the openjdk dependency closure; platform concern, not Tomcat's. |
| Drop `/etc/cups` | EL10 | REVIEW-DROP | CUPS printing config pulled in by the dependency closure (root:root); appears only in the EL10 capture. |
| Drop `/etc/pki/nssdb` | EL | REVIEW-DROP | System NSS shared DB (root:root), crypto dependency closure. |
| Drop `/var/lib/ca-certificates-java` | Ubuntu | REVIEW-DROP | System Java CA trust store (dependency); trust management is platform. |
| Drop `/var/cache/tomcat10` | Ubuntu | REVIEW-DROP | systemd `CacheDirectory` (service runtime, mode 0750); service writes it, team does not. |
| Drop `/var/lib/tomcat` (`/var/lib/tomcat10`) broad ACL | all | REVIEW-DROP | CATALINA_BASE; the team writes only `webapps/` (already group-writable via pam_group). Broad recursive ACL removed; EL install state kept via `ownership`. |
| Drop `/var/lib/tomcats` | EL | REVIEW-DROP | Empty multi-instance base (root:root); unused by this single-instance deploy. |
| Add `/var/log/tomcat` (`/var/log/tomcat10`) read | all | REVIEW-ADD | `/var/log` excluded from footprints by default; Ubuntu unit confirms the dir (`RequiresMountsFor` + `ReadWritePaths`). |
| `profile_name` `tomcat10` → `tomcat` | Ubuntu | REVIEW-CHANGE | Normalized to the app-dir slug (`check_profiles`); cosmetic — names the sudoers file / group.conf label, not any unit or path. |
| Keep `/etc/tomcat`, `/var/lib/tomcat` ownership | EL | as captured | Enforces install-time state; `group: tomcat` is the vendor default, not our change. No ownership entry on Ubuntu — vendor state is already correct. |

## 3. Access model for this app class

**app-server.** The reduced decision table this profile uses (full matrix in the
[access model](../../concepts/access-model.md#choosing-the-mechanism-the-decision-matrix)):

| Need | Mechanism here | Note |
| --- | --- | --- |
| Team identity + read baseline | **pam_group** into `tomcat` | Also carries the deploy write (below). |
| Write **deploy / content** (`webapps`, `Catalina`, CATALINA_HOME) | **vendor group-writable dir** — nothing added | The package already ships `0775 *:tomcat`; pam_group makes membership mean write. **No setgid, no ACL** — contrast nginx/apache, whose web roots are not group-writable and need a `2775` chown. |
| Write **config** (`/etc/tomcat`) | **ACL** | Team-only; the service account is not granted config write. |
| Read **logs** (`/var/log/tomcat`) | **ACL** (+ default ACL) | See §10 — Tomcat self-rotates. |

Because the deploy write is pure group membership over vendor permissions, this
profile makes **no ownership change at all** (EL keeps the captured entries;
Ubuntu has none) — there is no reviewed drift to accept-list (contrast §8 of the
nginx/apache runbooks).

## 4. Apply

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/tomcat/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
```

Artifacts to eyeball afterwards:

- `/etc/sudoers.d/tomcat-rg-<host>-app-restricted` — `visudo -cf` it; confirm the
  `tomcat`/`tomcat10` systemctl + journalctl lines and `daemon-reload`.
- the `group.conf` line mapping the AD group into `tomcat` (pam_group).
- `getfacl /etc/tomcat /var/log/tomcat` — team group present with `rwx` / `r-x`
  and a matching `default:` entry.
- **no** ownership diff to check on Ubuntu; on EL the two `ownership` entries are
  no-ops against vendor state (that is intended).

Applying is non-breaking while the team still holds app-full (group nesting).

## 5. Verify

Verified with `scripts/verify-profile.sh tomcat <distro>` (init container, real
playbook apply, allow/deny probes, real `--tags cleanup`). On a live host:

```bash
sudo -l -U <pilot>                          # exactly the scoped grants
sudo systemctl restart tomcat               # allow (Ubuntu: tomcat10)
sudo journalctl -e -u tomcat                # allow (granted spelling)
sudo systemctl restart sshd                 # DENY
echo x | sudo tee /usr/lib/systemd/system/tomcat.service   # DENY (read-only units)
vi /etc/tomcat/server.xml                   # allow (config ACL)
# behavioral pam_group — FRESH ssh login:
id                                          # must list 'tomcat'
touch /var/lib/tomcat/webapps/.probe && rm $_   # deploy write via group
```

A stale session is a false negative — pam_group is per-login. **Behavioral
check that matters for this app:** after a profile-scoped `restart`, confirm
Tomcat actually comes up (`journalctl -u tomcat` shows the startup line) and a
test WAR deploys — the deploy path depends on group membership *and* the WAR
being readable by the `tomcat` account (the umask gotcha in [dev §3](dev.md#3-editing-configuration)).

## 6. Flip

Remove the team from `<hostname>-app_full` (restricted grants already live via
nesting), `loginctl terminate-user <user>` per user, `sss_cache -E`. Confirm on
a fresh login: `id` shows no `wheel`, `id` **does** show `tomcat`, and `sudo -l`
shows only the profile.

## 7. Revoke / tighten later

Three moments: edit the profile pre-apply; override at apply time
(`-e '{"declarative_access_local_groups": []}'` to drop the group and go ACL-only
— but then the team loses webapp deploy, since deploy is *only* via group here);
or full revoke with the same command + `--tags cleanup`. Cleanup removes the
sudoers file, the `group.conf` pam_group line, and the ACLs (incl. defaults). It
deliberately leaves parent-directory traverse ACLs (shared across profiles) and
**never reverts ownership** — the EL `ownership` entries stay as applied (they
match vendor state anyway). No linger to disable (no rootless quadlets).

Note the clean revoke property of the zero-drift model: because the deploy write
was pure group membership over vendor permissions, dropping the `group.conf` line
removes deploy access with **nothing left behind** on the webapps dir — no ACL to
strip, no ownership to undo.

## 8. Drift and patching

- **`rpm -V tomcat` / `dpkg --verify tomcat10`:** this profile changes no file
  modes or ownership, so — unlike the nginx/apache setgid content dir — there is
  **nothing to add to the golden-baseline accept-list**. A clean `rpm -V` stays
  clean.
- **ACLs are invisible** to `rpm -V`/`dpkg --verify`; verify them with `getfacl`.
- **Package updates replace files and shed file ACLs** (and can reset config-dir
  modes): re-run playbook 5 after patching — it is idempotent. A Tomcat *major*
  version bump on Ubuntu (`tomcat10` → a future `tomcat11`) changes unit name,
  paths, and the account gid → **re-capture and re-review**, do not hand-edit.
- **authselect** runs can drop the pam_group line from `/etc/pam.d/sshd` on EL —
  re-run the role or wire the module into a custom authselect profile. This
  matters more for Tomcat than most apps: pam_group is the *primary* grant, so
  losing that line silently removes webapp-deploy access (config ACL survives).

## 9. TLS: key ownership and rotation

Tomcat is the **self-service keystore** exception —
[concepts/tls-ssl.md](../../concepts/tls-ssl.md#per-application-class-exceptions).
Java reads a PKCS12 keystore, not PEM files, and that keystore lives inside the
granted config tree (`/etc/tomcat/keystore.p12`, `root:tomcat 0640`). So:

- **The team rotates.** They build the keystore in `/etc/tomcat` (their config
  ACL covers it) and run their granted `restart` — Tomcat has no graceful
  reload, so rotation is a brief outage, not a zero-downtime reload.
- **Consequence to accept knowingly:** the private key is *within the team's
  reach* for Tomcat (it is in the keystore in their tree), unlike nginx/httpd
  where the key stays root-only and the team never reads it. This is the
  documented exception, not a review miss — record it as an accepted posture for
  the host.
- No cert-admin opt-in profile is needed: the team already owns the tree the
  keystore lives in. The platform PEM key dir (`/etc/pki/tls/private` /
  `/etc/ssl/private`) stays out of the profile as always.

## 10. Logs

`journalctl` grants are per-unit scoping — never substitute `systemd-journal`
group membership (host-global journal read). Tomcat is a **self-rotating
application** ([concepts/logging.md](../../concepts/logging.md#self-rotating-applications)):
juli writes one file per day under `/var/log/tomcat*` and rotates them itself, so
the ACL-mask question moves from the logrotate `create` line into juli's file
mode.

- **EL:** logrotate ships **disabled** (`/etc/logrotate.d/tomcat.disabled`); juli
  owns rotation. Pre-flip test: trigger a day-roll (or restart) and `getfacl` the
  fresh dated file — confirm no `#effective:---`. If juli's mode ever masks the
  ACL, that is an application-config change, not a logrotate one.
- **Ubuntu:** `catalina.out` is rotated by `/etc/logrotate.d/tomcat10` from
  `cron.daily`; the dated `*.log` files are still juli's. Run the standard
  pre-flip test on the logrotate side:

  ```bash
  logrotate -f /etc/logrotate.d/tomcat10
  getfacl /var/log/tomcat10/catalina.out   # team group present, no #effective:---
  ```

The logrotate fragment is outside the profile — retention changes are an ops
request. `[needs-runtime-confirmation]` on any host whose juli `logging.properties`
or logrotate fragment was customized.

## 11. Known risks (from `risks[]`)

EL9/EL10 carry **no** `risks[]` entries. Ubuntu carries **three high** entries —
all the same finding, one per unit-file path:

| Finding | Severity | Decision | Owner |
| --- | --- | --- | --- |
| `tomcat10.service` grants ambient `CAP_NET_BIND_SERVICE` (`/usr/lib/...`, `/lib/...`, and the `multi-user.target.wants` symlink) | high | **Accept.** The Debian unit ships this so Tomcat can bind ports <1024 as the unprivileged `tomcat` user instead of running as root — arguably *more* least-privilege than the alternative. Default connectors are 8080/8443 (unprivileged), so it is latent unless someone configures a low port. It is a **vendor-owned unit setting, not in our profile** (read-only-units), so the team cannot widen or exploit it via any granted verb. | platform |

If org policy forbids ambient capabilities regardless, removing them is a systemd
hardening **drop-in** authored by ops in a change window (`[Service]` with
`AmbientCapabilities=` cleared) — it is not a restricted-profile grant, and it
would break any privileged-port connector the team has configured. `[app-knowledge]`:
the EL unit does not set this capability because EL Tomcat is expected behind a
reverse proxy or on 8080; the divergence is packaging, not an install defect.

## 12. Storage and growth

Install-time floor, summed from the `filesystem` block of each
`footprints/<distro>/footprint-tomcat.json` (same captures as §1):

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| Install floor (all added entries) | **305.0 MB** | **454.9 MB** | **412.2 MB** |
| Dominated by | OpenJDK **8** under `/usr/lib/jvm` (+ its `/lib/jvm` usr-merge twin): 281.8 MB — **92%** | OpenJDK **21**: 427.3 MB — **94%** | OpenJDK **21**: 385.7 MB — **94%** |
| Tomcat's own trees | `/etc/tomcat` + `/var/lib/tomcat` + `/usr/share/tomcat`: **0.3 MB** | **0.3 MB** | `/etc/tomcat10` + `/var/lib/tomcat10` + `/usr/share/tomcat10`: **1.1 MB** |
| Not in the floor | `/var/log/tomcat` (`/var/log` excluded from footprints); `webapps/` ships **empty** | same, plus `webapps-javaee/` — also empty | `/var/log/tomcat10`; `webapps/` ships a 2 KB `ROOT` app; `/var/cache/tomcat10` is created at runtime by `CacheDirectory=` |

Treat that as a **floor, not a forecast** — it answers "will it fit", never
"how fast will it fill"
([sizing](../../concepts/storage.md#sizing-the-footprint-is-a-floor-not-a-forecast)).
Two things to read off it before provisioning. First, this is **among the
heaviest floors in the library** — the largest of all on alma10, top-two on the
other two (compare nginx at 3 MB, apache at 10 MB); only MySQL on alma9
(335.4 MB) and MariaDB on Ubuntu (493.0 MB) are larger anywhere. Second, it is
heavy because of the **JVM dependency closure, not Tomcat** — Tomcat's own trees
are about 1 MB, and the alma9→alma10 jump is the JDK the package pulls (8 vs
21), not a Tomcat difference. Budget the working set on top of the floor, never
inside it.

**Growth drivers**, worst first:

| Driver | Bounded? | Detail |
| --- | --- | --- |
| `webapps/` — deployed WARs **and their exploded copies** | **No** | The unbounded path on a stock install. Tomcat unpacks each WAR beside itself, so a deploy transiently needs **roughly double** the WAR `[app-knowledge]`. Ships empty (EL) / 2 KB (Ubuntu), so 100% of this tree is the team's. |
| `/var/log/tomcat*` dated juli files | **No by default** | juli writes one file per day and *rolls* but does not *prune*; retention needs `maxDays` in `logging.properties` `[app-knowledge]`. On EL nothing else prunes them — the fragment ships disabled (§10). `[needs-runtime-confirmation]` per host. |
| `catalina.out` | Ubuntu: **yes**, `/etc/logrotate.d/tomcat10` via `cron.daily`. EL: nothing would rotate it | Both distros' units are `Type=simple` with no `StandardOutput=`, so stdout/stderr land in the **journal**, not a file — the classic unbounded `catalina.out` only exists if a start script or `logging.properties` redirects to it. `[needs-runtime-confirmation]` on any given host. |
| journal | Yes — journald `SystemMaxUse` | Where Tomcat's console output actually goes on both distros (§10). |
| `/var/cache/tomcat10` work dir (Ubuntu) | **No** | Compiled JSPs; systemd `CacheDirectory=`, mode `0750`, **REVIEW-DROPped** (§2) — the team can neither see nor clear it. N/A on alma9/alma10 — no cache dir in the capture. |

**Separate volume: warranted**, and for a different reason than a database. The
floor is 305–455 MB before the team deploys anything, and `webapps/` growth is
unbounded and doubles during deploys. Mount it at **CATALINA_BASE** —
`/var/lib/tomcat` (Ubuntu `/var/lib/tomcat10`) — the app's own data path, which
carries `webapps/` and is already the path the profile knows. Split
`/var/log/tomcat*` onto a second volume only where juli retention is unresolved.
Never invent a new path and symlink.

Ubuntu's unit already declares `RequiresMountsFor=/var/log/tomcat10
/var/lib/tomcat10`, so systemd orders the service after both mounts. **The EL
units declare no such dependency** — add `RequiresMountsFor=` in an ops drop-in,
or Tomcat can start before the volume is mounted and deploy into the directory
hidden underneath it.

**Ordering: mount → restore → re-apply → `getfacl`.** Full procedure in
[separate volumes: when and where](../../concepts/storage.md#separate-volumes-when-and-where).
The app-specific tail, including the one step the generic procedure does not
cover:

```bash
# after mounting at CATALINA_BASE, before re-applying:
install -d -o root -g tomcat -m 0775 /var/lib/tomcat/webapps   # Ubuntu: -o tomcat -g tomcat
restorecon -Rv /var/lib/tomcat                                 # EL, enforcing

ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/tomcat/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
getfacl /etc/tomcat /var/log/tomcat         # team group back, default entry present
stat -c '%A %U:%G' /var/lib/tomcat/webapps  # drwxrwxr-x root:tomcat (Ubuntu tomcat:tomcat)
```

**Why the extra `install -d`.** Tomcat's deploy grant is *vendor group-write*,
not an ACL (§3), and the profile deliberately changes no permissions on
`webapps/`: EL's two `ownership` entries cover `/etc/tomcat` and
`/var/lib/tomcat` only, and the Ubuntu profile has none. So playbook 5 restores
the config and log ACLs after a mount but **will not recreate `webapps/` as
`0775`** — re-apply alone leaves `getfacl` looking correct while deploy stays
broken. That is the one sharp edge of the zero-drift model (§7): nothing to
strip on revoke, but nothing to restore after a mount either.

**Log retention.** Two sinks, and the file sink is the one with no default
ceiling:

| | alma9 | alma10 | ubuntu 24.04 |
| --- | --- | --- | --- |
| Shipped fragment | `/etc/logrotate.d/tomcat.disabled` `0644` — **inactive** | same | `/etc/logrotate.d/tomcat10` `0644` — **active** |
| Runs from | N/A on alma9 — fragment disabled, no cron entry (`cron_jobs` 0 in §1) | N/A on alma10 — same | `/etc/cron.daily/tomcat10`, the single cron job in §1 |
| Dated `*.log` files | juli self-rotates; pruning only via `maxDays` | same | same |
| Console output | journal (`Type=simple`), journald caps apply | same | same |

Neither the fragment nor juli's `logging.properties` sits in any profile:
**retention and frequency changes are an ops request** in a change window. Flag
the EL default at handover — a disabled fragment plus juli's keep-forever
default means dated logs grow unbounded until someone sets `maxDays`.
