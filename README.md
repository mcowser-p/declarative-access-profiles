# declarative-access-profiles

Evidence-based access profiles for Linux applications: each application's
install is captured as a [cairn](https://github.com/mcowser-p/cairn)
footprint, the generated `declarative_access` profile is **reviewed by a
human**, verified end to end in a container, and published here together
with documentation for the two people who have to live with it — the dev
team that operates the application under restricted access, and the ops
team that applies and maintains the lockdown.

Profiles are applied with the
[`mcowser_p.declarative_access`](https://github.com/mcowser-p/ansible-declarative-access)
collection:

```bash
ansible-playbook -i inventory playbooks/5_apply_access_profile.yml \
  -e @profiles/nginx/almalinux-9-access.yml \
  -e "group_name=<hostname>-app_restricted"
# revoke: same command + --tags cleanup
```

## Where things live

| Path | What it is |
| --- | --- |
| `profiles/<app>/` | `<distro>-raw.yml` (byte-exact cairn output, never edited) + `<distro>-access.yml` (reviewed — the diff between the two IS the review) |
| `footprints/<distro>/` | The committed footprint JSON evidence each profile derives from |
| `docs/apps/<app>/` | `dev.md` (your life after lockdown) + `ops.md` (lockdown runbook) |
| `docs/role-evals/` | Public Ansible role evaluations (adopt / wrap / build) per app |
| `docs/blog/` | How all the parts fit together |
| `docs/windows-plan.md` | Windows Server 2025 / winget pre-work plan |
| `skills/evaluate-profile/` | The LLM skill that turns a fresh capture into this repo's artifact set |
| `matrix.yml` | The app × distro capture matrix (single source of truth) |
| `scripts/` | Batch capture + per-profile verification harnesses |

## Regenerating or extending

Both harnesses take the two upstream projects as environment variables, so
point them at wherever your clones live:

```bash
export CAIRN_SRC=/path/to/cairn                       # github.com/mcowser-p/cairn
export ACCESS_SRC=/path/to/ansible-declarative-access # the collection

# authoritative: capture on real EC2 AMIs (one instance per distro)
scripts/capture-matrix-ec2.sh --dry-run     # resolve AMIs + print the cost estimate
scripts/capture-matrix-ec2.sh               # ~$0.03; instances self-terminate
scripts/capture-matrix-ec2.sh sweep         # reap anything a failed run left behind

# authoritative: apply/probe/revoke every reviewed profile on real instances
scripts/verify-profile-ec2.sh almalinux-9
scripts/verify-profile-ec2.sh --app nginx ubuntu-24.04

# fast, low-fidelity local pre-check in containers (misses the OS auth
# surface: authselect, SELinux enforcing, real sshd/PAM)
scripts/capture-matrix.sh
scripts/verify-profile.sh nginx almalinux-9
```

`CAIRN_SRC` must point at a cairn tree whose `footprint` command supports
`--access-vars`; the harness refuses to run otherwise. Once that lands in a
cairn release, `CAIRN_SRC` goes away in favour of installing the released
package — each script header notes the simplification.

## License

Code (`scripts/`, `tools/`, `skills/`, CI) is Apache-2.0; documentation,
profiles, and footprints are CC BY 4.0. See [LICENSE.md](LICENSE.md) — and
the note there that profiles are reviewed evidence, not a security
guarantee for your environment.

> **Status:** the GitHub Pages workflow (`.github/workflows/pages.yml`) is
> committed **disabled**. Enable it (uncomment the push trigger, drop the
> `if: false`) once you want the site published.
