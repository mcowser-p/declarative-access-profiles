# Access model

This page is the canonical description of how a declarative access profile turns into
actual permissions on a host: the four grant mechanisms the `declarative_access` role
(applied by playbook 5, `5_apply_access_profile.yml`, in the `mcowser_p.declarative_access`
collection) composes, the decision matrix for choosing between them, why the *who* is
never part of a profile, and the security tradeoffs you accept when you apply one.
Application guides state only their app-specific instantiation of these mechanics and
link here; how a profile is captured and derived is covered in [footprints.md](footprints.md),
and how it is reviewed, applied, and eventually revoked in [lifecycle.md](lifecycle.md).

## WHAT is in the profile, WHO is not

A profile describes **what** an install created — units, timers, quadlets, config and
state directories, log locations. **Who** gets access is passed at apply time and is
never stored in the profile:

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
    -e @myapp-access.yml -e "group_name=<hostname>-app_restricted"
```

The separation exists for one reason: it makes the profile a reviewable, reusable
artifact. The same vars file grants a setup crew today, a steady-state team next month,
and (with `--tags cleanup`) revokes either — identity never contaminates the diff you
review.

The entity is almost always one of two AD groups per host:

- `<hostname>-app_full` — the setup-window admin group. `<hostname>-app_restricted` is
  nested inside it, so setup admins hold the steady-state grants too.
- `<hostname>-app_restricted` — the steady-state group the profile is applied to, and
  what everyone is flipped to when the setup window closes (see
  [lifecycle.md](lifecycle.md)).

## The four grant mechanisms

The role composes four independent mechanisms. Each key in the vars file is gated —
absent means not granted — so a profile uses only the subset it needs.

### 1. Scoped sudoers (systemctl and journalctl)

The role renders `/etc/sudoers.d/<profile>-<entity>` containing exact-command grants.
The verb set differs **per unit type**, because the unit types differ in what the verbs
can safely mean:

| Unit type | Vars key | systemctl verbs granted | Why this set |
|---|---|---|---|
| Services | `declarative_access_services` | `start stop restart reload status enable disable mask unmask` (bare name and `.service` form) | The team owns the service end to end. |
| Timers | `declarative_access_timers` | Same minus `reload`, and **only** with the explicit `.timer` suffix | `systemctl start foo` resolves to `foo.service`, so a bare-name grant would target the wrong unit; timers have nothing to `reload`. |
| Quadlets | `declarative_access_quadlets` | Lifecycle only: `start stop restart status` | Quadlet services are produced by a systemd generator at daemon-reload; they cannot be enabled or disabled, and `mask` would wedge the generated unit. Boot behavior lives in the `[Install]` section of the quadlet file itself. [app-knowledge] |

Every unit grant also carries the matching `journalctl -u` variants (see
[logging.md](logging.md)) and `systemctl daemon-reload` — reload is included because
edited unit files take effect only after one, and it cannot be scoped (see
[tradeoffs](#security-tradeoffs)).

### 2. POSIX ACLs — including default ACLs

ACLs grant the entity access to *exactly* the named paths, layered on top of the
normal Unix permissions:

- `declarative_access_files_modify` — `rw` access ACL on individual files (typically
  the installed unit/quadlet files).
- `declarative_access_folders_modify` — recursive `rwX` access ACL **plus a default
  ACL** on the directory.
- `declarative_access_folders_read` — recursive `rX`, plus default ACL.

The default ACLs are load-bearing, not a nicety: services keep creating files after
the profile is applied — log rotations, new state files, generated config. A default
ACL makes every new file inherit the grant; without it the grant silently decays to
"only the files that existed on apply day". If you ever hand-edit ACLs, preserve the
`default:` entries on directories or the profile stops covering new content.

### 3. pam_group — session-scoped group membership

`declarative_access_pam_group` + `declarative_access_local_groups` map the entity into
a *local* group (e.g. `apache`, `tomcat`, or `wheel`) for the duration of an SSH
session, via a line the role manages in `/etc/security/group.conf`. Properties that
define the mechanism:

- **Granted at login, sshd-only.** pam_group assigns the extra group in
  `pam_sm_setcred`, so it applies when a PAM session is established — the role's
  `sshd;!tty*;…` line scopes it to SSH logins. It is not a change to `/etc/group`:
  `getent group apache` will never show the AD users, but `id` inside their SSH
  session will. [app-knowledge]
- **Self-maintaining.** Membership covers whatever the group owns — including files
  that do not exist yet — with zero per-path configuration.
- **Per-session, not per-account.** Sessions opened before the grant do not have the
  group, and sessions open at revocation keep it until logout (see
  [tradeoffs](#security-tradeoffs)).

The pipeline uses pam_group at two layers: host-level playbooks map
`<hostname>-app_full` into `wheel` for setup-window sudo, and application profiles map
`<hostname>-app_restricted` into the app's service group where the decision matrix
below says so.

### 4. loginctl lingering — rootless quadlets

Rootless quadlets under `~/.config/containers/systemd/` generate **user** units their
owner manages with `systemctl --user` — no sudo, no ACLs, no grant at all. The only
thing the role does for them is `loginctl enable-linger <owner>`
(`declarative_access_linger_users`). Without lingering, the owner's user-level systemd
manager — and every rootless service under it — stops when their last session ends;
with it, the manager starts at boot and logind keeps `XDG_RUNTIME_DIR` alive, which
rootless podman requires. [app-knowledge]

Lingering is per-user, not per-profile: cleanup of one profile disables lingering for
its listed users and stops **all** their rootless services at session end, including
ones other profiles rely on.

## Choosing the mechanism: the decision matrix

Why not just one mechanism? Because on stock EL packages, joining the service group
grants almost nothing: config ships root-owned (often already world-readable), and
state/log directories are `0700`/`0770` with `root` group — so bare `apache`/`nginx`/
`postgres` membership confers no write anywhere and usually no log read.
[app-knowledge] Making group membership *mean* something requires ownership changes
(setgid group-owned directories), and doing that indiscriminately has side effects the
matrix below avoids.

| Need | Mechanism | Why |
|---|---|---|
| Team identity + read baseline | **pam_group** into the service group | Zero-setup, self-maintaining; covers future files automatically. |
| Write **content / deploy** dirs (web roots, webapp dirs) | **setgid group-owned** directory (`2775`) — or nothing, where the package already ships one group-writable | Writes flow through group membership; setgid makes new files inherit the group. Prefer vendor-shipped group-writable dirs: they need no change at all. |
| Write **config** (`/etc/httpd`, `/etc/nginx`, …) | **ACL** | Grants the *team* without also letting the *service account* rewrite its own config — a setgid chgrp to the service group would do both. Config dirs frequently reference or contain key material; see [tls-ssl.md](tls-ssl.md) before widening them. |
| Read **logs** (`0700`/`0770` root-group dirs) | **ACL** | You cannot sensibly `chgrp` a log directory to the service group; an ACL reaches it without ownership surgery. See [logging.md](logging.md). |

Whether a specific vendor package already ships group-writable paths — and therefore
whether a profile needs any ACL or ownership change at all — is a per-app, captured
fact, stated in each application guide.

**The database exception.** Database profiles are **config-scoped**: config and logs
via ACL, **no pam_group** into the service group by default, and **never** the data
directory. The `mysql`/`postgres` group owns the raw data files, and filesystem access
to them bypasses every GRANT the database enforces — DB administration happens through
the SQL client, not the filesystem. [app-knowledge] The group option remains available
at apply time for teams that accept that tradeoff knowingly.

**Setgid is reviewed drift.** A setgid content dir (e.g. `/var/www` → `root:apache
2775`) deviates from vendor-shipped ownership, so `rpm -V` and drift monitoring will
flag it. That is intentional, reviewed drift — record it in the golden-baseline
accept-list ([lifecycle.md](lifecycle.md)) so it never reads as tampering.

## Platform constraints: where a mechanism means something else, or nothing

The decision matrix above says what each mechanism *grants*. These are the places
where the platform decides it grants less than the profile says — or nothing —
without the profile being wrong and without anything failing loudly.

All three were found on the KVM AD fleet, 2026-08-24, during ad-lab access testing.
They are platform facts rather than per-app ones, so they apply to every profile.

### pam_group cannot confer sudo on Ubuntu 25.10+

Ubuntu 25.10 and later ship **`sudo-rs`** in place of sudo (26.04: `0.2.13-0ubuntu1`,
binary at `/usr/lib/cargo/bin/sudo`, package `sudo-rs`). **It does not honour
pam_group-derived membership.** So the `admin_full`/`app_full` → `wheel`/`sudo` path
**does not work on 26.04 at all**.

What was measured, on Ubuntu 26.04 joined to `LAB.INTERNAL`:

- `/etc/sudoers` carries the usual `%sudo ALL=(ALL:ALL) ALL`.
- In an SSH session as the AD principal, `id -nG` **includes** `sudo` — pam_group did
  its job.
- sudo-rs refuses regardless: `sudo: I'm sorry <user>. I'm afraid I can't do that`.
- `ops`, whose membership is *real* rather than session-granted, escalates on the same
  host. That contrast is the discriminator: it rules out a wrong password and a missing
  rule, and it means **a working `ops` proves nothing** about a pam_group-granted tier.
- The same probes on AlmaLinux 10 with classic sudo escalate to uid 0 for both tiers.

**The mechanism is inference, not measurement.** sudo-rs's source was not read.
"Resolves membership through NSS rather than the calling process's supplementary
groups" is the explanation that fits every observation above, and it may well be
right — but what is established is the behaviour, not the cause.
`[mechanism needs-verification 2026-08-24]`

`app_restricted` is unaffected: its rights come from an explicit sudoers rule naming
the group, not from membership of a local admin group. The useful generalisation is
therefore **the restricted tier is platform-independent and the admin tier is not** —
the application underneath is incidental, so this is not a reason to prefer one engine
over another.

**The refusal text is a trap of its own.** sudo-rs answers
`I'm sorry <user>. I'm afraid I can't do that`. That string is a **refusal**, so a DENY
probe grepping for sudo's traditional `not allowed to execute` finds no match and
**passes for the wrong reason** — reporting a correctly-denied grant and a
never-evaluated one identically.

### The same group.conf line means different things per distro

`*;*` for `admin_full` is written into `group.conf` correctly on EL — and is
**latent**, because `pam_group.so` is wired only into `/etc/pam.d/sshd` there. The
wider scope cannot reach `su` or the console. Ubuntu 26.04 has the module in `login`,
`remote` and `sshd`, so the identical line genuinely means "all services".

Measured with `grep -l pam_group /etc/pam.d/*`: AlmaLinux 10 returns `sshd` alone;
Ubuntu 26.04 returns `login`, `remote`, `sshd`. `group.conf` was byte-for-byte
equivalent on both.

On EL, "all services" is therefore *unreachable* rather than merely unused — and an
inspection of `group.conf` reads as applied when it is not. Verify the PAM stacks, not
the config file.

### `sudo -n` cannot test authorisation at all

Against a password-requiring rule, `sudo -n` answers *"a password is required"* for a
**permitted** command and a **forbidden** one alike. Any DENY probe built on `-n`
therefore passes whether or not the grant is scoped — three probes in the ad-lab suite
were green for exactly this reason before it was caught.

`sudo -n` answers one question honestly — *is this passwordless?* — and that is a
narrower claim than *can this account escalate*. To test authorisation, supply the
password and assert on the refusal message. Where no password exists (key-only tenant
accounts), pair the `-n` check with a structural one — the account is in no admin
group and owns no sudoers entry — and state that it is a proxy.

This is the same failure mode as asserting on `.failed` after `failed_when: false`:
a probe that cannot distinguish the outcomes it is named for, reporting success either
way. Prefer ground truth — the file is absent, the group does not contain them — over
a return code whose meaning is overloaded.

## Security tradeoffs

Read these before applying a profile; each is inherent to the mechanism, not a bug.

- **A write ACL on a unit file is root-equivalent for that unit.** Someone who can
  edit `ExecStart=` (or drop `User=`) and run `sudo systemctl daemon-reload && sudo
  systemctl restart myapp` executes arbitrary commands as root. This is a deliberate,
  accepted tradeoff — the team installed and owns the application. If your environment
  cannot accept it, remove `declarative_access_files_modify` at review or override it
  to `[]` at apply time: the team keeps systemctl/journalctl but loses the edit path
  (`systemctl edit` is never in any granted verb set).
- **`daemon-reload` is system-global.** It re-runs all generators and reloads every
  unit definition on the host; systemd offers no per-unit variant, so any unit grant
  includes the global one. [app-knowledge]
- **sudoers matches exact command strings — argument order included.** The grants
  enumerate specific command forms; a semantically identical invocation with arguments
  in a different order (or an extra flag) does not match and is denied. This fails
  *closed* — the symptom is a false "sorry, user may not run" denial, not a privilege
  hole. The fix is to run the command in the granted form, not to widen the grant.
- **pam_group membership is evaluated per login.** Sessions that predate the grant do
  not have the group — a freshly applied profile produces false negatives ("I'm in the
  AD group but can't write") until the user logs in again. Symmetrically, sessions
  open at revocation keep the membership until logout. When access looks wrong, check
  `id` *inside a fresh SSH session* before anything else. [needs-runtime-confirmation]
- **Package updates shed file ACLs.** An update replaces the packaged file, and the
  replacement does not carry the old file's ACL, so grants on unit files and packaged
  config quietly vanish after `dnf update`. [app-knowledge] The remedy is cheap:
  re-run playbook 5 with the same inputs — it is idempotent and simply restores the
  declared state. Verify with `getfacl` after major updates if the app's grants matter
  operationally. [needs-runtime-confirmation]
- **`authselect apply-changes` can drop the pam_group line.** On authselect-managed
  hosts, applying changes regenerates `/etc/pam.d/sshd`, discarding the `pam_group.so`
  line the role inserted. [app-knowledge] Re-run the role afterwards, or wire the
  module into an authselect custom profile so regeneration preserves it.
- **Review is the control point.** The profile is derived from what the install *did*,
  which is not automatically what the team *should* keep administering. The vars file
  is small on purpose — read it before it reaches playbook 5.
