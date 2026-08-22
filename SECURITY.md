# Security policy

## What this repository is, and what it is not

These are **reviewed access profiles and the evidence behind them** — not a
security guarantee for your environment. Each profile records what a
specific distribution package installed on a specific OS version on the date
in its provenance header, and what a human decided to grant on that basis.

Before applying anything here to a system you care about:

- capture your **own** footprint — your install may differ from ours
  (different version, different options, a config-management layer);
- re-run the review against your own threat model;
- verify on a non-production host first.

The profiles carry a deliberate, documented tradeoff surface. Read
[the access model](https://mcowser-p.github.io/declarative-access-profiles/concepts/access-model/)
before applying — in particular that a write ACL on a unit file is
root-equivalent for that unit, and that `daemon-reload` cannot be scoped.

## Reporting a vulnerability

**A profile that grants more than the application justifies is a security
bug.** So is a documented procedure that would widen access if followed.
Please report those.

- **Non-sensitive issues** — open a
  [bug report](https://github.com/mcowser-p/declarative-access-profiles/issues/new?template=bug-report.yml)
  and choose *"Profile grants too much"*. Public discussion is fine for an
  over-broad grant in a published profile: the profile is already public,
  and nothing here is deployed on our infrastructure.
- **Sensitive issues** — if a report would expose a live system, use
  [private vulnerability reporting](https://github.com/mcowser-p/declarative-access-profiles/security/advisories/new)
  instead of an issue.

Please include the profile path, the distro, and the specific grant you
believe is too wide — plus, ideally, the evidence from a footprint showing
the install does not justify it.

## Scope

| In scope | Report to |
| --- | --- |
| A profile in `profiles/` granting more than the install justifies | here |
| Documentation that would widen access if followed | here |
| A harness script in `scripts/` doing something unsafe on a target host | here |
| The apply/revoke mechanism (the role, playbook 5, cleanup) | [ansible-declarative-access](https://github.com/mcowser-p/ansible-declarative-access) |
| Footprint capture (missing units, wrong paths in the raw export) | [treadmark](https://github.com/mcowser-p/treadmark) |

## What the footprints contain

The committed footprint JSONs are diffs of stock package installs on
throwaway cloud instances: paths, modes, ownership, unit definitions, and
file hashes. They contain **no file contents**, no credentials, and no
infrastructure detail beyond the ephemeral hostnames of instances that were
terminated the day they were captured.

If you believe something sensitive did land in this repository, report it
privately using the link above rather than opening an issue.
