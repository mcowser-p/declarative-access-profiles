# Microsoft SQL Server — your life after lockdown

You deployed SQL Server, you're now in `<hostname>-app_restricted`, and this
page is everything you can still do. The short version is unusual for this
library: **your admin surface is the service, and everything else is SQL.**
SQL Server on Linux keeps no config in `/etc`, has no drop-in directory, and
holds its own config file inside a data root you cannot enter — so unlike the
nginx or mysql guides there is no "edit config here" section with a granted
path. There is a granted unit, a granted journal, and a TCP port where the
rest of your job lives.

## §0 First command: `sudo -l`

```console
$ sudo -l
User appdev may run the following commands on mse01:
    (root) NOPASSWD: /usr/bin/systemctl start mssql-server, /usr/bin/systemctl
        stop mssql-server, /usr/bin/systemctl restart mssql-server, ...
    (root) NOPASSWD: /usr/bin/journalctl -u mssql-server *, ...
```

sudo matches the whole command string, argument order included — copy your
spellings from `sudo -l` output, not from memory or this page.

## §1 Your grants at a glance

| What | How it's granted | Example |
|---|---|---|
| Service control over `mssql-server` | scoped sudoers verbs | `sudo systemctl restart mssql-server` |
| Unit inspection | scoped sudoers | `sudo systemctl status mssql-server` |
| Engine logs | per-unit journalctl grant | `sudo journalctl -u mssql-server -e` |
| Everything database-shaped | **a SQL login over 1433**, not the filesystem | `sqlcmd -S localhost -U <you> -C` |

Not granted, on purpose: no config paths (none exist outside the closed data
root), no membership in the `mssql` group (that group owns the raw data files
— membership would bypass every SQL GRANT), no `/opt/mssql` (vendor
binaries), no key material.

## §2 Administering your systemd units

One service, full verb set: `start`, `stop`, `restart`, `status` on
`mssql-server`. `daemon-reload` is granted globally as usual — you will not
need it (you cannot edit the unit; if a unit change is required, that is an
ops request).

There is no `reload`: sqlservr re-reads `mssql.conf` only at process start,
so every settings change that goes through `mssql-conf` (ops) ends in YOUR
granted `restart`. Server-level settings changed via `sp_configure` mostly
take effect on `RECONFIGURE` without a restart — prefer them when the setting
offers both routes.

## §3 Editing configuration

You don't — not as a filesystem act. The decision tree:

1. **Database/server settings with a SQL surface** (`sp_configure`,
   `ALTER SERVER CONFIGURATION`, `ALTER DATABASE ... SET`): yours today, over
   your SQL login, budget permitting no restart at all.
2. **Host-level engine settings** (`memory.memorylimitmb`, `network.*`,
   trace flags — anything in `mssql.conf`): an **ops request**. Root runs
   `/opt/mssql/bin/mssql-conf set ...`; you run the granted `restart` when
   they hand it back.
3. **"Why did my write fail?"** — if you tried to touch
   `/var/opt/mssql/...`: that is the closed data root working as designed,
   not drift. There is no `getfacl` diagnostic to run because there is no ACL
   to have; the path is 0700 `mssql:mssql`.

## §4 TLS / SSL administration

- **What you can do**: run the granted `restart` after ops rotates material;
  verify from the client side (`sqlcmd` encrypts by default; `-C` trusts the
  self-signed bootstrap cert — its presence in your connection string is the
  tell that real CA material hasn't landed yet).
- **What you can't**: the key and cert are root-placed
  (`mssql-conf network.tlscert/tlskey`), key readable by the `mssql` account
  only. Key dirs are in NO profile, this one included.
- **Renewal flow**: expiry checking needs no privileges
  (`openssl s_client -connect host:1433 -starttls mssql` variants, or just
  the platform's monitoring); platform drops the files and runs mssql-conf;
  you run the restart.

## §5 Logs and log rotation

- Granted, verbatim spellings: `sudo journalctl -u mssql-server -e`,
  `sudo journalctl -u mssql-server --since -1h`.
- The errorlog file itself lives in `/var/opt/mssql/log/` — closed data
  root, no file grant. Same content, two open routes: the journal (above) or
  SQL — `EXEC sys.xp_readerrorlog 0, 1, N'<filter>'` over your login.
- **Rotation is not your problem and not logrotate's either**: the errorlog
  self-cycles on restart and by count (`errorlog.numerrorlogs`, an ops
  setting). There is no `/etc/logrotate.d` entry for this app, so the usual
  rotated-file-readability drill is N/A.

## §6 Everything else you'll eventually need

- **Secrets**: your SQL login credentials come from your team's secret store;
  nothing password-shaped lives in a path you can read on the host (sa's
  password is root-only by design). Never ask for it on a command line —
  `SQLCMDPASSWORD` in your environment beats `-P`.
- **Timers you may see** (`mssql-logbackup`, `mssql-logrestore` in the
  db-lab): platform-owned DR plumbing, not granted. If backup freshness
  alarms fire, that is an ops page, not a you-page.
- **Change window**: back into `<hostname>-app_full` → do the work → hand
  back and re-flip. Same process as every app here.
- **Denied-command playbook**: read the denial, run `sudo -l`, and if the
  verb you need is missing, request it against the profile — quoting the
  denial, not paraphrasing it.

## §7 Per-distro differences

| | almalinux-9 | almalinux-10 | ubuntu-24.04 | ubuntu-26.04 | amazonlinux-2023 |
|---|---|---|---|---|---|
| package | `mssql-server` (packages.microsoft.com) | same | same | **N/A — not in SQL Server 2025's support matrix (Ubuntu caps at 24.04)** | **N/A — not a supported SQL Server platform** |
| unit | `mssql-server.service` | same | same | — | — |
| account | `mssql` | `mssql` | `mssql` | — | — |
| config root | none in `/etc`; `mssql.conf` inside the data root | same | same | — | — |
| drop-in dir | none — no drop-in model exists | same | same | — | — |
| log route | journal / `xp_readerrorlog` | same | same | — | — |
| MAC | SELinux enforcing, sqlservr unconfined | same | AppArmor, no profile ships | — | — |
| extra deps | + `saslauthd` (disabled, ungranted) | same | none | — | — |

The uniformity is the point: Microsoft ships one layout everywhere it ships
at all. The differences that matter (editions, DR shape) are deployment
decisions, not distro facts — see the db-lab.

## §8 Cheat sheet

```bash
sudo -l                                          # what exactly you hold
sudo systemctl status mssql-server               # is it up
sudo journalctl -u mssql-server -e               # why is it not up
sqlcmd -S localhost -U $USER -C                  # everything else is SQL
#   settings:  EXEC sp_configure; RECONFIGURE;
#   errorlog:  EXEC sys.xp_readerrorlog 0, 1, N'error';
#   edition:   SELECT SERVERPROPERTY('Edition');
sudo systemctl restart mssql-server              # after ops changes mssql.conf
```
