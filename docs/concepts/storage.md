# Storage, disks, and growth

What an install costs on disk, what grows afterwards, who is allowed to do
something about it, and the one mistake that silently revokes a team's
access. This page is the single home for the doctrine; app pages state the
per-app numbers and growth drivers and link here.

## Storage is an access problem, not only a capacity problem

After the flip, a dev team **cannot**:

- attach, partition, or `mkfs` a volume,
- `mount` anything or edit `/etc/fstab`,
- `chown` a mount point,
- change `/etc/logrotate.d/<app>` or journald limits.

None of that appears in any access profile, and it can't: `mount` and
`fstab` are root-equivalent. **Disk provisioning is ops work, and it has to
happen before handover** — or later, in a change window
([lifecycle](lifecycle.md)). A team that discovers at 3am that its data
volume is full can restart its service and read its logs, and nothing else.

The practical consequence for the deploy side: declare storage needs in the
handover manifest *before* lockdown, the same way units and paths are
declared.

## The trap: a mount hides the ACLs underneath it

This is the failure everyone hits exactly once.

A profile grants the team ACLs on, say, `/var/lib/pgsql`. Ops later attaches
a volume and mounts it at that path. The ACLs are still on the **now-hidden**
directory; the freshly-mounted filesystem root comes up `root:root 0755`
with no ACLs at all. The team's access disappears with no error anywhere,
and a setgid content directory loses its setgid bit and group at the same
time.

**Rule: mount first, then apply — and re-apply the profile after any mount
change.** Playbook 5 (`5_apply_access_profile.yml`) is idempotent, so
re-running it is always the fix:

```bash
# after mounting anything under a granted path
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/<app>/<distro>-access.yml \
  -e "group_name=<hostname>-app_restricted" -l <host>
getfacl /var/lib/<app>      # confirm the team entry is back
```

Two more that only show up on real hosts:

- **SELinux context** (EL, enforcing). A new filesystem does not inherit the
  policy label the service needs, and the daemon will refuse to start with a
  permission error that looks nothing like SELinux. Label the mount, don't
  just `chown` it:
  ```bash
  semanage fcontext -a -e /var/lib/pgsql /data/pgsql   # or the app's own type
  restorecon -Rv /data/pgsql
  ```
- **ACL support on the filesystem.** xfs always supports ACLs; ext4 does by
  default on current kernels. A filesystem mounted `noacl` makes every
  `folders_modify` grant a silent no-op.

## Sizing: the footprint is a floor, not a forecast

Every footprint records file sizes, so the install-time cost of each app is
evidence, not estimation — the numbers live in each app's ops page. They
answer "will it fit," never "how fast will it fill." The
[install-time-is-not-runtime caveat](access-model.md) applies in full: the
capture sees what the installer wrote, not what the service accumulates.

Budget separately for: the install floor, the working set (data, content),
the transaction/replication logs, the log files, and headroom for whatever
the app needs to *rewrite* itself (a database dump, an AOF rewrite, a
package upgrade).

## What actually grows

| Class | Bounded by default? | The real growth driver |
| --- | --- | --- |
| journald | **Yes** — `SystemMaxUse` defaults to 10% of the filesystem, capped at 4 GB | only unbounded if an operator raised the cap |
| App log files | **Yes, if** the package ships a logrotate fragment and it's adequate | verbose access logging; a fragment nobody reviewed |
| Databases | **No** | the dataset, plus **WAL / binlogs** — the classic disk-full cause |
| Caches with persistence | **No** | dataset size; an AOF rewrite transiently needs roughly double |
| Web/app content | **No** | whatever the team writes into the content directory |
| Memory-only caches | N/A — no disk growth | — |

**Transaction logs deserve their own attention.** They are the component
that fills a disk fastest and least visibly: a PostgreSQL replication slot
that nobody consumes pins `pg_wal` forever, and MariaDB/MySQL binlogs grow
until `binlog_expire_logs_seconds` (or an explicit purge) says otherwise.
Neither is fixed by log rotation, and neither is something a restricted team
can change — the settings live in config the team *can* edit on some
distros, but the cleanup usually needs the service account or root.

## Separate volumes: when and where

Give an app its own volume when its growth is unbounded and its failure mode
is "fills the root filesystem" — in practice, any database, and any app that
writes large content. Mount it at the app's existing data path (so the
profile keeps working) rather than inventing a new path, and remember the
re-apply rule above.

Ordering for ops, once:

1. attach the volume, partition/`mkfs` (xfs or ext4),
2. add it to `/etc/fstab` (by UUID, `nofail` if it's non-critical to boot),
3. mount it **at the app's data path**,
4. restore ownership/mode and — on EL — the SELinux label,
5. **re-apply the access profile**, then `getfacl` to confirm,
6. record the mount in the ops record so the next reviewer knows the path is
   a mount point.

## Monitoring is ops, reporting is shared

The team can see usage (`df -h`, `du` inside their granted paths) but cannot
fix a full disk. Alerting thresholds, retention policy, and volume growth
are ops responsibilities. What the team owes ops is early warning and an
honest growth estimate at handover; what ops owes the team is a threshold
that fires before the service stops.

## Growing existing volumes

In-place growth (cloud disk → partition → LVM → filesystem) is
automated by the
[mcowser_p.fleet_medic](https://github.com/mcowser-p/fleet-medic)
collection's `disk_expand` role — threshold-driven, capped, and
cleanup-first. Growing in place never remounts, so the ACL grants on
the filesystem survive. Attaching **new** volumes remains the manual
six-step procedure above — and the mount-hides-ACLs rule applies:
re-apply the access profile after any mount change.
