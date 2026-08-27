# Access-profile verification suite

The pytest port of `scripts/_verify-remote.sh`. Same probes, same guests, same
reviewed profiles — different guarantees.

```bash
# on the KVM host (0.9 cannot drive a remote hypervisor)
export LIBVIRT_URI=qemu:///system
export HOLY_QCOW_SRC=$HOME/holy-qcow
export ACCESS_SRC=$HOME/ansible-declarative-access

uv venv .venv-tests && uv pip install --python .venv-tests/bin/python -r tests/requirements.txt

.venv-tests/bin/python -m pytest --distro almalinux-9              # one distro
.venv-tests/bin/python -m pytest --distro almalinux-9 --app nginx  # one cell
.venv-tests/bin/python -m pytest --distro almalinux-9 --stamp      # ...and rewrite VERIFIED:
```

One guest per process, one distro per process. Parallelise the way the labs
already do — five processes, five distros:

```bash
for d in almalinux-9 almalinux-10 ubuntu-24.04 ubuntu-26.04 amazonlinux-2023; do
  .venv-tests/bin/python -m pytest --distro "$d" --stamp \
    --junitxml="out/verify/$d.xml" > "out/verify/$d.log" 2>&1 &
done; wait
```

The drivers already scope teardown per distro, so concurrent runs do not reap
each other's guests.

## What this changes

**Every cell appears.** The bash driver iterated the profiles on disk, so an N/A
cell and a never-reviewed cell both simply failed to appear — and a run over
amazonlinux-2023 reported "8 passed" as though 8 were the matrix. All 11 apps now
produce a case in one of three states:

| State | Meaning |
|---|---|
| `N/A: <reason>` | `matrix.yml` says the cell is impossible, and says why |
| `no reviewed profile: ...` | possible, but not yet reviewed — work outstanding |
| pass / fail | actually verified |

**The application must be up before anything is asserted about it.** A capture
once returned `OK` for mysql/ubuntu-24.04 while silently missing `pam_group`, the
`mysql` group and all three ownership entries: mysqld had not finished
initialising and nothing noticed, because an exit status cannot see content.
`_profile_paths_missing` asserts the reviewed profile's own paths exist before
the profile is applied. It earned its place on its first run, catching a broken
multi-line install that had reported success.

**Teardown is a guarantee, not a trap.** The bash drivers used
`trap kvm_teardown_scoped EXIT INT TERM`, and a trap handler is not an exit path
unless it says so — a SIGTERM tore the guest down and let the run continue,
reporting five apps as FAIL when the run had merely been interrupted. Verified
here by sending SIGTERM mid-run:

```
[apache] PASSED
[caddy]  PASSED
[haproxy]
!!!!!!!!! KeyboardInterrupt: signal 15 !!!!!!!!!
============ 2 passed in 158.07s ============
```

Guest destroyed, and haproxy is neither passed nor failed — it is incomplete,
which is the truth. `pytest_configure` installs the SIGTERM handler explicitly:
pytest routes SIGINT into `KeyboardInterrupt` on its own, but Python's default
SIGTERM disposition kills the process with no finalizers, which would have
regressed on the exact signal that caused the incident. SIGKILL remains
unhandleable by anyone — `capture-matrix-kvm.sh sweep` is still the backstop.

## What it does not change

`kvm-lib.sh` is still the only implementation of launching, lease polling,
ProxyJump derivation and scp. The fixtures call it. Nothing about VM mechanics
was rewritten, because none of it was wrong — what moved is *when teardown is
guaranteed to run*, which is a property bash traps could not give.

The ansible verify playbooks in the labs are untouched and should stay that way:
asserting on a database's own answer is what ansible is for.

## Status

Proven over the full matrix on 2026-08-27: **51 passed, 4 skipped, 0 failed,
0 errors** across 55 cases, five distros running concurrently, 13 minutes
wall-clock, no stray guests.

| Distro | Tests | Passed | Skipped |
|---|---|---|---|
| almalinux-9 | 11 | 11 | 0 |
| almalinux-10 | 11 | 10 | 1 |
| ubuntu-24.04 | 11 | 11 | 0 |
| ubuntu-26.04 | 11 | 11 | 0 |
| amazonlinux-2023 | 11 | 8 | 3 |

Same 51 cells the shell path verifies, reported as 55 cases rather than 51 --
the four N/A cells now carry their recorded reason instead of being absent.

The provenance snippet is byte-identical to the one in
`scripts/verify-profile-kvm.sh`, so a stamp written by either path says the same
thing about the same guest. That run was deliberately made **without** `--stamp`:
a suite proving itself should not also rewrite the evidence it is judged against.

`scripts/verify-profile-kvm.sh` and `_verify-remote.sh` still work and are still
the documented path. Retiring them is now a decision rather than a risk.

## Windows

```bash
.venv-tests/bin/python -m pytest --platform windows-2022          # one platform
.venv-tests/bin/python -m pytest --platform windows-2022 --stamp  # ...and stamp it
```

`--distro` and `--platform` select the family; a run collects only the module for
the one it was given, so the reported counts always match the matrix.

**windows-2022: passing** as of 2026-08-27, ~8 minutes. All granted and revoked
checks, clean teardown.

**windows-2025: blocked, and not by a bug.** The IIS profile requires JEA, and a
JEA endpoint *is* a WinRM PSSession configuration -- `Register-PSSessionConfiguration`
writes into `WSMan:\localhost\Plugin\`. The windows-2025 image ships WinRM
disabled, which `matrix-windows.yml` already records, so the apply fails before
any probe runs. Both facts were written down; nothing had connected them.
Resolving it is a decision: enable WinRM in the image, record the cell N/A, or
split JEA out of the profile as a conditional component.

### Two things this port found

The probe read `'C:\...\RoleCapabilities\$prof.psrc'` in SINGLE quotes, so it
opened a file literally named `$prof.psrc` -- the real one is `iis.psrc`. Both
JEA checks were judging an empty string and had never passed. The naive fix is
also wrong: in double quotes `"$prof.psrc"` parses as a property access, so it
needs `$($prof).psrc`.

Which means **windows-2022's previous `VERIFIED: 2026-08-23` stamp recorded a
verification that could not have happened** -- it was committed in the same
changeset as the probe, and the probe could not pass. The stamp now on that file
was earned by a run that actually passed.

The shell driver could not have surfaced either: it collapsed all fourteen
checks into `grep -q "RESULT: PASS"`. That grep also reads a log truncated per
platform but appended per app, so a second Windows app's FAIL would be masked by
the first app's PASS -- latent only because `matrix-windows.yml` declares one app.
