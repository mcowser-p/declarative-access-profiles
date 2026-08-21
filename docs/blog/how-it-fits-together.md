# Access derived from evidence: locking a server to exactly what the install created

A team needs root to deploy their application. They get it "temporarily."
Three years later they still have it, because nobody can say what they'd
lose if you took it away. This is the story of how to answer that question
mechanically — by deriving each team's steady-state access from what their
install actually put on the server — and the parts that make it work end to
end.

Everything below is real and tested: the profiles in this repo were
generated from footprints captured on live AlmaLinux 9/10 and Ubuntu 24.04
EC2 instances (SELinux enforcing, real PAM stack), reviewed by hand, and
verified — apply, allow/deny probes, a behavioral SSH login, revoke — on
those same instances.

## The problem: root during setup, root forever

Two things usually happen instead, and both rot. Either an admin
hand-curates a sudoers file per team and it drifts out of sync with reality
the first time the app changes; or ops does everything through tickets and
becomes the bottleneck the team routes around. The question nobody can
answer cheaply is the one that matters: **what is the minimal access this
team actually needs to run what they deployed?**

## The idea: the footprint is the truth

The install already answered it. Diff the server against a clean baseline
after the team finishes deploying, and everything the install created — the
systemd units, timers, podman quadlets, directories, service accounts —
*is* the access surface. Nothing else is load-bearing for that team.

So we capture that diff, derive a starting access profile from it, and — the
part that keeps this honest — **a human reviews and tightens it before
anything is applied.** Derived access is a first draft, never an
auto-grant. As the handover step tells the team: *the footprint is the
truth; the manifest is your claim.*

```mermaid
flowchart LR
    A[clean baseline] --> B[team installs<br/>app-full window]
    B --> C[cairn footprint<br/>--access-vars]
    C --> D[human review<br/>raw → reviewed]
    D --> E[apply to<br/>rg.&lt;host&gt;.app-restricted]
    E --> F[verify<br/>allow / deny / behavioral]
    F --> G[flip:<br/>remove from app-full]
```

## The parts

**cairn footprint** captures the install-time diff and parses the
security-relevant objects into structured form: units (and the identity
they run as), timers, quadlets, the directories with owners and modes,
service accounts, sudoers files, and a `risks[]` list a human should read
first. Re-running it produces byte-identical output, which makes reviews
diffable.

**The `--access-vars` exporter** turns that model into a `declarative_access`
profile. The derivation encodes real operational knowledge: bare service
names become the full `systemctl` verb set plus the exact `journalctl`
spellings; timers keep their explicit `.timer` suffix (a bare name would
resolve to the `.service` — the wrong unit); quadlets get lifecycle-only
verbs because generator units can't be enabled or masked;
`StateDirectory=`/`LogsDirectory=` directives fill in directories the file
diff didn't show; and where an install-created group already has group-write
on a directory, the exporter routes it through group membership instead of
an ACL — zero deviation from the vendor's permissions.

**The declarative_access role** applies four kinds of grant: a scoped
sudoers file, POSIX ACLs (with *default* ACLs on directories — remember
that, it's why rotated logs stay readable), a `pam_group` line that places
the team into a local group at SSH login, and `loginctl enable-linger` for
rootless quadlets. Who gets the access is never in the profile — the entity
is passed at apply time.

**Two AD groups per server** carry the lifecycle: `<hostname>-app_full`
(admin during setup, mapped to `wheel` via pam_group) nested *inside*
`<hostname>-app_restricted` (the steady-state grant target). Because full is
nested in restricted, applying a profile grants the team its scoped access
immediately while they still hold admin — so applying never breaks a
working setup window. The flip is then a single operation: remove the team
from app-full and terminate their sessions.

**The deploy side** (a template repo the teams work from) walks them through
installing packages and their own app, then a **handover** that records a
manifest — units, service accounts, paths — and declares the server ready.
**The ops lockdown skill** does the rest: capture, review against the
manifest, apply, verify, flip.

**Verification** is where the claims become credible. Allow probes exercise
every granted verb; deny probes confirm `systemctl restart sshd` and
`dnf install` and vendor-unit edits are refused; and a **behavioral
pam_group test** logs in over real SSH and checks `id` shows the mapped
group — proven on AlmaLinux 9/10 and Ubuntu 24.04, on real instances where
authselect, SELinux, and the PAM stack are all live.

## Worked example: nginx

The raw export (from a real AlmaLinux 9 AMI) grants the nginx service, its
vendor unit files, and its config, cache, and unit drop-in directories. The
review tightens it to this shape (the full file, with the reasoning, is in
[the nginx profiles](https://github.com/mcowser-p/declarative-access-profiles/tree/main/profiles/nginx)):

- **service control** on `nginx` — kept.
- **vendor unit files** — dropped. A write ACL on a unit file is
  root-equivalent for that unit (`ExecStart=` + a granted `daemon-reload` +
  restart). This becomes a *read-only-units* profile.
- **config** `/etc/nginx` — a write ACL for the team group (the nginx
  service account must *not* be able to rewrite its own config, so config is
  never group-owned to the service group).
- **content** `/usr/share/nginx/html` — a setgid, group-owned directory, so
  the team writes content through the `nginx` group they gain at login and
  new files inherit the group with no ongoing upkeep.
- **logs** `/var/log/nginx` — a read ACL (added in review; `/var/log` is
  excluded from footprints by default).

After the flip, `sudo -l` shows exactly those `systemctl`/`journalctl`
lines and nothing else. `sudo systemctl reload nginx` works; `sudo
systemctl restart sshd` and `sudo dnf install` are refused; editing
`/etc/nginx/conf.d/*.conf` works via the ACL; `id` on a fresh login shows
the `nginx` group.

One thing every dev hits first: sudo matches the *whole* command string,
argument order included, so `journalctl -u nginx -e` is a different string
from the granted `journalctl -e -u nginx`. The rule is: copy from `sudo -l`.

## Two days in the life

**A developer** edits a config drop-in (ACL), validates with `nginx -t`,
reloads with their granted verb, and reads the error log through the
directory ACL — no ticket for any of it. When they need a new module
installed, that's a denied action and a change-window request; ops re-adds
them to app-full for the window, they work, they hand over again.

**An operator** takes a server whose manifest reads `ready-for-lockdown`,
captures the footprint, reviews the raw export against the manifest
(anything the profile grants that the team didn't declare gets questioned),
applies to `app-restricted`, runs the allow/deny/behavioral probes, and
flips the team out of app-full with `loginctl terminate-user` +
`sss_cache -E`. After the next patch Tuesday, `rpm -V` flags the one
intentional setgid on the content directory — which is on the golden
accept-list — and nothing else.

## The awkward trio: TLS, logs, logrotate

These three are where an access model meets operational reality, so they get
their own concept pages. The short version:

- **TLS keys** live root-owned in `/etc/pki/tls/private` (or `/etc/ssl/private`
  on Ubuntu) and are in *no* profile. Key rotation is platform work; the team
  runs their granted reload to pick up the new cert. Two apps break the
  pattern: Tomcat's keystore sits inside the granted config tree, so keystore
  rotation is team self-service; PostgreSQL's key sits inside the closed data
  directory, so it's always ops. ([TLS concept](../concepts/tls-ssl.md).)
- **Rotated logs stay readable** because the profile set a *default ACL* on
  the log directory — tomorrow's file inherits the grant. But logrotate's
  `create <mode>` line is the new file's group-class mask: `create 0640`
  preserves an inherited read ACL, `create 0600` silently caps it to
  `#effective:---`. The diagnostic is `getfacl`; the ops pre-flip test is
  `logrotate -f` then `getfacl`. ([Logs concept](../concepts/logging.md).)

## Honest limits

- **Install-time is not runtime.** The footprint sees what landed on disk,
  not what the app opens under load. It is one input to the access model;
  review and runtime observation stay human work.
- **A write ACL on a unit file is root-equivalent** for that unit — a
  deliberate, documented tradeoff, and the reason reviewed profiles drop
  vendor units. Opt out entirely with `files_modify: []`.
- **`daemon-reload` is global** and can't be scoped.
- **authselect** can regenerate `/etc/pam.d/sshd` and drop the pam_group
  line; re-run the role or use a custom authselect profile.
- **pam_group is SSH-session-scoped** — cron and `sudo -u` sessions don't
  get the group.
- **Package updates replace files and shed their ACLs**, and can reset
  package-directory modes; re-run the apply after patching (it's idempotent).

## Windows

Capture already works there — cairn emits a `1.0-windows` footprint (file +
registry diff, service and scheduled-task identities) from winget/MSI
installs. The enforcement analogs exist too — `icacls`, GPO Restricted
Groups, `sc.exe sdset`, `SeServiceLogonRight`, AppLocker — but there's no
exporter yet, and Windows can't enumerate the accounts an installer created
(the SAM isn't a readable file). The [Windows plan](../windows-plan.md) maps
the gap.

## Where to start

Pick an application, read its [dev guide](../index.md) for what a team keeps
after lockdown and its ops runbook for how the profile was derived, then
open the reviewed profile next to its `-raw.yml` sibling — the diff between
them is the whole argument. Then run the pipeline against a staging box and
watch a server end up with exactly the access its install justified, and
nothing more.
