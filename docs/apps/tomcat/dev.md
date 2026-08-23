# Tomcat — your life after lockdown

You deployed Tomcat; you're now in `<hostname>-app_restricted`. This page is
everything you can still do, and how. What ops decided and why is in the
[ops runbook](ops.md); your grants come from the reviewed profile for your
distro ([alma9](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/tomcat/almalinux-9-access.yml),
[alma10](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/tomcat/almalinux-10-access.yml),
[ubuntu 24.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/tomcat/ubuntu-24.04-access.yml),
[ubuntu 26.04](https://github.com/mcowser-p/declarative-access-profiles/blob/main/profiles/tomcat/ubuntu-26.04-access.yml)).

Tomcat is the application where **pam_group does the most**: the package ships
your deploy dirs group-writable to `tomcat`, so being in that group at login is
what lets you deploy webapps — no ACL, no ownership change. The rest of this
page uses the EL names (`tomcat`, `/etc/tomcat`, `/var/lib/tomcat`); the Ubuntu
equivalents are `tomcat10`, `/etc/tomcat10`, `/var/lib/tomcat10` on 24.04 and
`tomcat11`, `/etc/tomcat11`, `/var/lib/tomcat11` on 26.04 — see the
[per-distro table](#8-per-distro-differences). There is no Tomcat profile for
amazonlinux-2023: N/A — tomcat is not packaged in AL2023 core repos and AL2023
has no EPEL support.

## 0. First command: `sudo -l`

`sudo -l` prints your exact granted command lines. sudo matches the **whole
command string, argument order included** — `journalctl -u tomcat -e` is a
different string from the granted `journalctl -e -u tomcat` and will prompt for
a password. Copy from `sudo -l` output, not from memory.

## 1. Your grants at a glance

| What | How it's granted | Example |
| --- | --- | --- |
| Service control on `tomcat` (Ubuntu: `tomcat10`/`tomcat11`) | sudoers: `start stop restart reload status enable disable mask unmask`, bare and `.service` spellings | `sudo systemctl restart tomcat` |
| Its journal | sudoers: `journalctl -u tomcat`, `-e -u`, `-ef -u`, `--since -5m/-10m/-15m` variants (bare + `.service`) | `sudo journalctl -e -u tomcat` |
| `daemon-reload` | sudoers (global — see §2) | `sudo systemctl daemon-reload` |
| Config: `/etc/tomcat` | write **ACL** for your team group (+ default ACL for new files) | edit `server.xml`, add `conf.d/*.conf` |
| Webapp deploy + context config: `/var/lib/tomcat/webapps`, `/etc/tomcat/Catalina/localhost`, `/usr/share/tomcat` | vendor dirs owned `root:tomcat` `0775` (group-writable) — you're in `tomcat` at login via **pam_group**, so you write via group membership | `cp app.war /var/lib/tomcat/webapps/` |
| Logs: `/var/log/tomcat` | read **ACL** + default ACL | `less /var/log/tomcat/catalina.$(date +%F).log` |
| Service group at login | pam_group: `tomcat` — **next SSH login only**, SSH sessions only, not cron | `id` after a fresh login |

There is no config write ACL "and" a group grant fighting each other: the ACL on
`/etc/tomcat` covers the root-owned files (`server.xml`, `tomcat.conf`) that
group membership can only *read*; pam_group covers the vendor group-writable
deploy tree that no ACL touches. See the [access model](../../concepts/access-model.md)
for the four mechanisms.

## 2. Administering your systemd unit

The full verb set is granted for `tomcat.service` (Ubuntu: `tomcat10.service` /
`tomcat11.service`). There are no timers or quadlets in this profile.

**Tomcat has no graceful reload.** The packaged unit defines no `ExecReload`, so
`sudo systemctl reload tomcat` is in your granted set but returns an error / does
nothing. To pick up any change — config, a new keystore, a redeployed webapp that
does not hot-deploy — use `sudo systemctl restart tomcat`, which drops
connections briefly. Plan config changes for a quiet window.

`daemon-reload` is in your list because every unit grant carries it, but you will
rarely need it: this is a **read-only-units** profile (you cannot edit the unit
files), so there is no unit change of your own to reload. It stays host-global by
design — running it is harmless but affects every unit's metadata, not just
yours.

## 3. Editing configuration

Two trees, two mechanisms:

- **`/etc/tomcat` (config ACL).** `server.xml` (connectors, TLS), `tomcat.conf`,
  `tomcat-users.xml`, and drop-ins under `conf.d/` are root-owned and only
  *group-readable*; your write access comes from the ACL. Drop-in discipline:
  put JVM flags and startup options in `/etc/tomcat/conf.d/<intention>.conf`
  (the package already ships one, e.g. `java-9-start-up-parameters.conf`), one
  intention per file, rather than hand-editing the shipped files where you can
  avoid it.
- **`/etc/tomcat/Catalina/localhost` (group-writable).** Per-webapp context
  descriptors (`<app>.xml`) live here; the dir is `0775 root:tomcat` and you
  write it through your `tomcat` group membership, no ACL involved.

**Validate before you rely on it.** Tomcat has no offline `-t`-style config
checker (unlike `nginx -t`). The check is a restart plus the journal:

```bash
sudo systemctl restart tomcat
sudo journalctl -ef -u tomcat        # watch for the "Server startup" line or a stack trace
```

**"Why did my write fail?"** First: did you log in **after** the profile was
applied? pam_group membership is granted at login (§1), so a stale session is
not in the `tomcat` group. Then `getfacl <path>` — for `/etc/tomcat` you should
see your team group with `rwx`; for the deploy dirs you rely on group `tomcat`
being in your `id` output.

**Deploy gotcha (webapps is group-writable but *not* setgid).** When you
`cp app.war /var/lib/tomcat/webapps/`, the new file gets **your** primary group,
not `tomcat` — the dir has no setgid bit (zero-drift; ops did not change vendor
permissions). Auto-deploy only works if the `tomcat` service account can *read*
the WAR: with a normal `umask 022` your WAR is world-readable and Tomcat reads
it fine, but on a host hardened to `umask 027` the WAR lands `0640
you:yourgroup` and Tomcat cannot read it — the app silently never deploys. If a
deploy is ignored, check `ls -l` on the WAR and `chmod g+r,o+r app.war` (or ask
ops to set the setgid bit if your umask policy makes this recurring).

## 4. TLS / SSL administration

Tomcat is the **self-service keystore** exception in
[TLS under the access model](../../concepts/tls-ssl.md#per-application-class-exceptions) —
read that section, it is the doctrine; this is the app-specific instantiation.

Java does not read PEM files. Tomcat's certificate and key are packed into a
**PKCS12 keystore** that lives *inside your granted config tree*
(`/etc/tomcat/keystore.p12`, `root:tomcat 0640`), not in the platform key
directory. Because your config ACL already covers `/etc/tomcat`, building the
keystore and swapping it in is something **you** can do end to end:

```bash
# 1. (once) generate a key + CSR, get the .crt back from your CA — see
#    concepts/tls-ssl.md "CSR -> CA -> cert". The key stays on the host.
# 2. pack cert + key (+ chain) into a PKCS12 keystore in the granted tree:
openssl pkcs12 -export -name tomcat \
  -in myservice.crt -inkey myservice.key -certfile chain.crt \
  -out /etc/tomcat/keystore.p12
# 3. point server.xml at it (inside the <Connector port="8443"> SSLHostConfig):
#      <Certificate certificateKeystoreFile="/etc/tomcat/keystore.p12"
#                   certificateKeystorePassword="..." type="RSA"/>
# 4. pick it up — NO graceful reload, so a restart (brief outage):
sudo systemctl restart tomcat
```

Consequence worth understanding: because the keystore (which contains the
private key) sits in your granted tree, **you effectively hold the key** for
Tomcat. That is the deliberate exception — for nginx/httpd the key stays
root-only and the team never reads it, but Java's keystore model puts it where
you can manage it. Treat the keystore password and file with the same care as
the key itself.

**Monitoring expiry needs no privileges** (certs are public):

```bash
openssl s_client -connect localhost:8443 </dev/null 2>/dev/null \
  | openssl x509 -noout -dates
```

**Always ops:** first-time TLS enablement that installs software; changing a
connector to a port below 1024 (on Ubuntu the unit already carries
`CAP_NET_BIND_SERVICE`, but the change itself is still reviewed — see
[ops §11](ops.md#11-known-risks-from-risks)); any change to key file
permissions.

## 5. Logs and log rotation

Tomcat logs in two places:

- **The journal** — with `Type=simple`, Tomcat's stdout/stderr (`catalina.out`
  content) is captured by systemd. Read it with the granted `journalctl`
  spellings (verbatim in `sudo -l`): `sudo journalctl -e -u tomcat` for "did it
  start / why did it die".
- **juli file logs** under `/var/log/tomcat/` — `catalina.<date>.log`,
  `localhost.<date>.log`, `localhost_access_log.<date>.txt`, etc. Read these via
  your log-dir ACL with **no sudo**: `tail -f`, `less`, `grep`.

**Rotation is app-specific here.** Tomcat's juli handler writes **one file per
day** and rotates itself — so on EL the package ships logrotate *disabled*
(`/etc/logrotate.d/tomcat.disabled`) and juli owns rotation; on Ubuntu logrotate
(`/etc/logrotate.d/tomcat10` / `tomcat11`, run from `cron.daily`) rotates
`catalina.out` while juli still self-rotates the dated files. Either way your read grant
survives because the profile set a **default ACL** on the log dir — tomorrow's
dated files inherit it (see [Logs & rotation](../../concepts/logging.md)).

Because juli (not logrotate) sets the mode of most of these files, the mask
gotcha lives in the **application's** logging config, not a logrotate `create`
line: this is the self-rotating case in
[concepts/logging.md](../../concepts/logging.md#self-rotating-applications). If a
dated log is ever unreadable, `getfacl` it and look for `#effective:---`.
`/etc/logrotate.d/tomcat*` is outside your grant — retention/frequency changes
are a request to ops.

## 6. Storage: what fills up, and what you can do about it

Two things grow here: **your webapps** under `/var/lib/tomcat/webapps` — a WAR
plus the exploded directory Tomcat unpacks beside it, so a deploy transiently
needs roughly **double** the WAR `[app-knowledge]` — and `/var/log/tomcat`,
where juli writes a fresh dated file every day. Rotation is not retention: juli
rolls files but prunes nothing by default, and on EL the logrotate fragment
ships **disabled** (§5), so dated logs accumulate until someone sets `maxDays`
`[needs-runtime-confirmation]`.

You can *see* usage — `df -h`, and `du -sh` inside your granted paths. You
cannot *fix* a full disk: `mount`, `mkfs`, `/etc/fstab`, `chown` on a mount
point, and edits to `/etc/logrotate.d/tomcat*` or journald limits are all ops
work needing a change window. Your one lever is housekeeping: delete your own
stale WARs and their exploded directories.

If ops mounts a volume over a granted path (`/var/lib/tomcat`,
`/var/log/tomcat`), the mount **hides** the ACLs underneath it and your access
disappears with no error — ops must re-apply the profile, and for Tomcat also
restore the deploy directory's group-write by hand
([ops §12](ops.md#12-storage-and-growth)). See
[the mount-hides-ACLs trap](../../concepts/storage.md#the-trap-a-mount-hides-the-acls-underneath-it).

## 7. Everything else you'll eventually need

- **Env / JVM options.** EL: the unit reads `/etc/tomcat/tomcat.conf` (inside
  your config ACL — set `JAVA_OPTS`, `CATALINA_OPTS` there) and optionally
  `-/etc/sysconfig/tomcat` (outside your grant; leave it to ops or use
  `conf.d`). Ubuntu (both releases): the unit sets `JAVA_OPTS` inline and reads
  no `EnvironmentFile`; the packaged env file is `/etc/default/tomcat10` /
  `tomcat11` (root-owned, **outside your grant** — an ops request), read by the
  start script `[app-knowledge]`, so self-service JVM tuning is limited to what
  `/etc/tomcat10` / `/etc/tomcat11` config (your ACL) can express. No file in
  any profile contains secrets by default; keep DB passwords in a webapp's own
  config, not world-readable under `/etc/tomcat`.
- **Timers you own:** none.
- **A bigger change** (install a JDBC driver into `CATALINA_HOME/lib`, add a
  connector on a privileged port, upgrade the package, edit the unit): that is a
  change window — ops re-adds you to `<hostname>-app_full`, you work, you hand
  over again.
- **A command is denied:** read the denial, run `sudo -l`, and if the need is
  real, request either the exact command grant or a change window.

## 8. Per-distro differences

Tomcat applies on four of the five distros; the divergence among those four is
the widest of any app in the library. Ubuntu 26.04 ships **Tomcat 11**
(`tomcat11`) — same access model as 24.04's `tomcat10`, but the Security
Manager machinery is gone (no `policy.d`, no `/var/lib/tomcat11/policy`, no
policy build step in the unit; Tomcat 11 removed Security Manager support
`[app-knowledge]`).

| | alma9 | alma10 | ubuntu 24.04 | ubuntu 26.04 | amazonlinux 2023 |
| --- | --- | --- | --- | --- | --- |
| Package / unit | `tomcat` / `tomcat.service` | `tomcat` / `tomcat.service` | `tomcat10` / `tomcat10.service` | `tomcat11` / `tomcat11.service` | N/A on amazonlinux-2023 — tomcat not packaged in AL2023 core repos and no EPEL support |
| Service account:group | `tomcat:tomcat` (uid/gid 53) | `tomcat:tomcat` (53) | `tomcat:tomcat` (987 — allocated at install) | `tomcat:tomcat` (982 — allocated at install) | N/A on amazonlinux-2023 |
| Config root | `/etc/tomcat` | `/etc/tomcat` | `/etc/tomcat10` | `/etc/tomcat11` | N/A on amazonlinux-2023 |
| Drop-in dir | `/etc/tomcat/conf.d` | `/etc/tomcat/conf.d` | none — `policy.d` only (Security Manager policy); JVM flags are an ops request (`/etc/default/tomcat10`) | none — and no `policy.d` either (Security Manager removed) | N/A on amazonlinux-2023 |
| Context descriptors | `/etc/tomcat/Catalina/localhost` | same | `/etc/tomcat10/Catalina/localhost` | `/etc/tomcat11/Catalina/localhost` | N/A on amazonlinux-2023 |
| Webapps (deploy) | `/var/lib/tomcat/webapps` (`0775 root:tomcat`) | same + `webapps-javaee` | `/var/lib/tomcat10/webapps` (`0775 tomcat:tomcat`) | `/var/lib/tomcat11/webapps` (`0775 tomcat:tomcat`) | N/A on amazonlinux-2023 |
| CATALINA_HOME | `/usr/share/tomcat` | `/usr/share/tomcat` | `/usr/share/tomcat10` | `/usr/share/tomcat11` | N/A on amazonlinux-2023 |
| Log dir | `/var/log/tomcat` | `/var/log/tomcat` | `/var/log/tomcat10` | `/var/log/tomcat11` | N/A on amazonlinux-2023 |
| Rotation | juli self-rotate; logrotate **disabled** | same | logrotate (cron.daily) + juli | logrotate (cron.daily) + juli | N/A on amazonlinux-2023 |
| Config validator | none — restart + journal | none | none | none | N/A on amazonlinux-2023 |
| TLS keystore | `/etc/tomcat/keystore.p12` (config ACL) | same | `/etc/tomcat10/keystore.p12` | `/etc/tomcat11/keystore.p12` | N/A on amazonlinux-2023 |
| pam_group group | `tomcat` | `tomcat` | `tomcat` | `tomcat` | N/A on amazonlinux-2023 |
| Unit ambient caps | none | none | `CAP_NET_BIND_SERVICE` | `CAP_NET_BIND_SERVICE` | N/A on amazonlinux-2023 |

## 9. Cheat sheet

```bash
sudo -l                                   # your exact grants — start here
sudo systemctl status tomcat              # health
sudo journalctl -e -u tomcat              # recent journal (granted spelling)
sudo journalctl -ef -u tomcat             # follow live (config-change check)
vi /etc/tomcat/server.xml                 # config edit (ACL)
sudo systemctl restart tomcat             # apply config/keystore — NO reload; brief outage
cp app.war /var/lib/tomcat/webapps/       # deploy (group-writable, chmod o+r if umask 027)
less /var/log/tomcat/catalina.$(date +%F).log   # file logs (ACL, no sudo)
id                                        # confirm 'tomcat' group (fresh login)
```
