# Footprints: how treadmark turns an install into evidence

This page is the canonical description of the **capture** side of the
pipeline: what [treadmark](https://github.com/mcowser-p/treadmark) records,
how a recorded install becomes a first-draft access profile, and what
capture can and cannot know. The **apply** side — how a reviewed profile
becomes actual permissions — is [access-model.md](access-model.md); the
process around both is [lifecycle.md](lifecycle.md).

## The idea: the install already answered the question

The question that matters is *"what is the minimal access this team needs
to run what they deployed?"* — and the install itself is the only honest
answer. Everything the team's installer created on the host — systemd
units, timers, podman quadlets, directories, service accounts — is the
surface they administer. Nothing else on the host is load-bearing *for
them*.

So instead of asking anyone, treadmark measures:

1. **Baseline** a clean host (fresh golden-image guest or container rootfs) — a scan of
   files, packages, units, users/groups before the team touches anything.
2. The team **installs** their application during the time-boxed
   `app-full` window.
3. **Capture the diff.** `treadmark footprint` compares the post-install
   host against the baseline and emits a structured JSON model of exactly
   what appeared or changed.

That JSON — committed under `footprints/<distro>/` in this repo — is the
evidence every profile traces back to.

## What a footprint records

The diff is *semantic*, not just a file list. For each thing the install
created, treadmark parses what it means:

| Observed in the diff | What treadmark extracts |
| --- | --- |
| systemd units / timers / quadlets | Identity (`User=`, `Group=`), exec lines, capabilities, hardening directives, state/config directory directives |
| New users and groups | `/etc/passwd`/`group` entries, plus membership changes on *pre-existing* groups |
| Files and directories | Paths, ownership, mode — including which service account owns what |
| sudoers drop-ins | The raw rules the installer granted itself |
| setuid/setgid binaries, file capabilities | Flagged into severity-ranked `risks` |

The model also carries per-principal `access_hints` with provenance — each
hint names the evidence it derives from.

## From footprint to first draft: `--access-vars`

`treadmark footprint --access-vars` maps each class of observation onto
one of the four grant mechanisms the
[`declarative_access` role](access-model.md#the-four-grant-mechanisms)
composes:

| Observation | Derived grant |
| --- | --- |
| Service / timer / quadlet the install created | Scoped `systemctl` sudoers grants for exactly those bare unit names |
| The unit/quadlet *files* themselves | `files_modify` ACL entries, so the team can edit what they shipped |
| Config, state, and log directories the install created | Folder ACL entries |
| Paths owned by install-created service accounts | `ownership` entries |
| Rootless quadlets under a user account | `loginctl` linger for that user |

The output is a vars file in exactly the shape playbook 5 applies —
committed here as `profiles/<app>/<distro>-raw.yml`, **byte-exact and
never edited**.

## The raw → reviewed diff IS the review

Derived access is a first draft, never an auto-grant. A human reviews each
raw export and commits the tightened result as `<distro>-access.yml` next
to it. Because the raw file is never edited, `diff *-raw.yml *-access.yml`
shows precisely what human judgment changed — every widening or narrowing
is visible, attributable, and reviewable in the git history. The
per-application review decisions are documented in each app's
[ops runbook](../apps/nginx/ops.md).

## What capture cannot know

Two honest limits, tagged throughout the docs per the
[evidence promise](../conventions.md):

- **Install-time only.** A footprint sees what the *installer* created. A
  need that only appears at runtime — a cache directory created on first
  request, a socket path, a log rotated into existence — is invisible to
  it. Claims about those carry `[needs-runtime-confirmation]` until a
  runtime check confirms them.
- **Fidelity depends on where you capture.** Container capture is fast but
  misses the OS auth surface (authselect, SELinux enforcing, real
  sshd/PAM). The authoritative footprints in this repo were captured on
  real KVM guests from holy-qcow golden images, one per distro — see the
  harnesses in `scripts/` and the
  [coverage table](../index.md#coverage) for which tier each profile
  reached.

## Where treadmark lives

treadmark is its own project — a cross-platform file integrity monitor of
which footprint capture is one workflow. Its
[repository](https://github.com/mcowser-p/treadmark) documents the full
CLI (baselines, drift detection, forensic workflows, Windows capture);
this repo consumes exactly one artifact from it: the footprint JSON and
the access-vars export derived from it.
