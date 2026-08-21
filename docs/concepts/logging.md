# Logs under the restricted access model

This page is the canonical reference for how a team reads its application's logs
after lockdown — that is, after playbook 5 (`5_apply_access_profile.yml`) from the
`mcowser_p.declarative_access` collection has applied the access profile and the team has
been flipped from `<hostname>-app_full` to `<hostname>-app_restricted` (see
[lifecycle](lifecycle.md)). It covers the two mechanisms the profile uses to grant
log access, why the grant survives log rotation, the one way rotation silently
breaks it (the mask gotcha), and which logging knobs remain an ops request.
Application guides state their specifics in a sentence or two and link here.

## Two log worlds, two mechanisms

A service's output lands in one or both of two places, and the restricted profile
grants each through a different mechanism — deliberately.

**1. The systemd journal (journald).** systemd captures everything a service prints
to its output streams — startup messages, crashes, warnings — into one central,
binary journal for the whole host. Access is granted as specific `sudo journalctl`
command spellings, every one of them scoped to the team's unit with `-u <unit>`
(see [the granted spellings](#reading-the-journal-the-granted-spellings) below).

**Never grant `systemd-journal` group membership instead.** The journal is a single
host-wide store: membership in `systemd-journal` (or `adm`) reads *all* of it —
every other service on the host, kernel messages, other users' session logs. There
is no group that means "this unit's journal only." Per-unit scoping exists only at
the command level, which is why the profile grants exact `journalctl -u` spellings
under sudo rather than a group.

**2. The application's own log files** under the app's log directory (typically
`/var/log/<app>/`). Web servers and databases write their detailed access and
error logs as plain text files [app-knowledge]. These are granted by a POSIX ACL
on the log directory (the profile's `folders_read` entry), so the team reads them
directly — `tail -f`, `less`, `grep` — with **no sudo at all**.

Rule of thumb: the journal for the service's health ("did it start? why did it
die?"), the log files for the application's detail. TLS handshake and certificate
failures typically surface in both — see [tls-ssl](tls-ssl.md).

## Reading the journal: the granted spellings

The profile grants this pattern of `journalctl` forms for the team's unit:

```bash
sudo journalctl -u <unit>                 # everything for the unit
sudo journalctl -e -u <unit>              # jump to the newest entries
sudo journalctl -ef -u <unit>             # follow live (like tail -f); Ctrl-C stops
sudo journalctl -u <unit> --since -15m    # time-window variants (--since / --until)
```

> **Argument order matters.** sudoers matches the command line as a literal
> string, not by what the command means. `journalctl -e -u nginx` and
> `journalctl -u nginx -e` are identical to journalctl but *different strings* to
> sudoers — only the spelling the profile granted will pass. If sudo refuses a
> journalctl command you believe you have, reorder the arguments to match the
> granted form. The general rule is covered in [the access model](access-model.md).

## Reading log files: the log-dir ACL

The profile's `folders_read` grant becomes a filesystem ACL giving the team's AD
group read (and directory-traverse) permission on the log directory. ACLs extend
the classic owner/group/other permissions with extra named entries, so the grant
works regardless of which system user or group owns the files. No sudo, no group
membership changes on the host — just:

```bash
tail -f /var/log/<app>/error.log
grep -i 'denied' /var/log/<app>/access.log
zless /var/log/<app>/access.log.2.gz
```

## Why rotated logs stay readable: the default ACL

Log rotation replaces files daily: logrotate renames `access.log` to
`access.log.1`, the service starts a fresh `access.log`, and older copies get
compressed to `.gz`. A grant placed only on today's files would decay overnight.

The profile prevents that by setting a **default ACL** on the log directory in
addition to the access ACL. A directory's default ACL is a template that every
file created inside it inherits at creation time. So:

- **Tomorrow's `access.log`** — created fresh after rotation — inherits the
  team's read entry the moment it appears.
- **The `.gz` archives** logrotate writes are new files in the same directory, so
  they inherit it too.
- **Renamed rotated files** (`access.log` → `access.log.1`) keep their ACL: a
  rename changes the file's name, not the file, and the ACL travels with the file.

The result is that the read grant applied once by playbook 5 keeps covering the
directory's contents indefinitely — with one exception, below.

## The mask gotcha

This is the one way log rotation silently defeats the ACL, and the canonical
description of it lives here.

When a file carries an ACL, its group-class permission bits stop meaning "the
owning group's permissions" and become the **ACL mask** — an upper bound applied
to every named-user and named-group entry on the file. logrotate's `create <mode>`
directive sets the mode of the fresh log file it creates after rotation, so **the
`create` line's group-class bits become the new file's ACL mask**:

- `create 0640 <user> <group>` — group-class bits are `r--`, so the mask allows
  read. The inherited group read ACL survives. **This is the correct form.**
- `create 0600 <user> <group>` — group-class bits are `---`, so the mask caps
  every ACL entry to nothing. The inherited entry is still *present* on the file
  but delivers no access. Nothing errors; the team simply gets
  `Permission denied` on every log newer than the change.

**Diagnostic:** `getfacl` the unreadable file and look for `#effective` lines. A
mask-capped file looks like this:

```text
$ getfacl /var/log/<app>/access.log
# file: var/log/<app>/access.log
user::rw-
group::---
group:host-app_restricted:r--    #effective:---
mask::---
other::---
```

The grant is there; the `#effective:---` tells you the mask is nullifying it.

**Ops pre-flip test:** before flipping a team to `<hostname>-app_restricted`
([lifecycle](lifecycle.md)), force a rotation and inspect the file rotation
creates:

```bash
logrotate -f /etc/logrotate.d/<app>
getfacl /var/log/<app>/<fresh-log-file>
```

If the fresh file shows no `#effective` caps, the grant will survive every future
rotation the same way.

## Rotation policy stays with ops

The rotation fragment lives at `/etc/logrotate.d/<app>` — outside the
application's own config tree — and the generated profile does **not** grant
write access to it by default. That is intentional: rotation policy is disk-budget
policy for the whole host, and (per the section above) a careless edit to the
`create` line can revoke the team's own log access. Retention or frequency
changes are therefore a request to ops. If a specific team genuinely must own its
fragment, ops can add that one path to the profile at review time — see
[the access model](access-model.md) for how per-path exceptions are reviewed.

## Self-rotating applications

Some applications bypass logrotate and rotate their own logs, which moves the
mask question from the logrotate fragment into the application's configuration.
The same mechanism applies: whatever mode the application creates its log files
with, the group-class bits of that mode act as the ACL mask on each new file.

The canonical example is PostgreSQL: its logging collector writes and rotates its
own log files inside the data directory [app-knowledge], and the mode of those
files is set by the `log_file_mode` parameter, which defaults to `0600`
[needs-runtime-confirmation on any given cluster]. At `0600`, every file the
collector creates is mask-capped exactly as in the gotcha above, and the log-read
grant is dead on arrival regardless of any ACL on the directory. For a
self-rotating app, the log-read grant *depends on* that setting — verify it (and
run the equivalent of the pre-flip test: trigger a rotation, `getfacl` the fresh
file) before relying on the grant.

## Quick reference

```bash
# service health / why it died
sudo journalctl -e -u <unit>
# follow the service live
sudo journalctl -ef -u <unit>
# the app's own detailed logs (no sudo — log-dir ACL)
tail -f /var/log/<app>/error.log
# is a log unreadable? check for a capped mask
getfacl /var/log/<app>/<file>          # look for '#effective:---'
# ops: prove the grant survives rotation (pre-flip test)
logrotate -f /etc/logrotate.d/<app> && getfacl /var/log/<app>/<fresh-file>
```
