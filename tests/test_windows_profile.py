"""IIS access-profile verification on Windows Server.

The Windows counterpart of test_access_profile.py, and a port of
scripts/verify-profile-windows.sh plus its two PowerShell probes.

The probes already do the right thing: _verify-windows-granted.ps1 makes nine
distinct checks -- scoped IIS delegation, three ACLs, the W3SVC and WAS service
SDDLs, the JEA session configuration and its role capability, and two negative
membership checks -- and _verify-windows-revoked.ps1 makes five more. What the
shell driver did with them is the problem: it collapsed all fourteen into a
single `grep -q "RESULT: PASS"`.

That grep has a latent bug worth naming, because it is the kind that surfaces
the day someone adds a second app. The log is truncated once per PLATFORM but
appended to per APP, so with two Windows apps the second one's `RESULT: FAIL`
is masked by the first one's `RESULT: PASS` still sitting in the file. Today
matrix-windows.yml declares only iis, so it cannot bite -- which is exactly why
it would go unnoticed until it did.

Here each PASS/FAIL line the probes emit becomes its own reported check, and a
failure names the checks that failed rather than the file to go read.
"""
from __future__ import annotations

import datetime
import pathlib
import re

import pytest
import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
GRANTED = REPO / "scripts" / "_verify-windows-granted.ps1"
REVOKED = REPO / "scripts" / "_verify-windows-revoked.ps1"

# "  PASS  <label padded to 46>  <detail>"
CHECK = re.compile(r"^\s*(PASS|FAIL)\s+(.+?)\s{2,}(.*)$")


def _checks(output: str) -> list[tuple[str, str, str]]:
    """Every check the probe reported, in order. An empty list means the probe
    produced nothing parseable, which is a failure in itself -- a probe that
    does not run looks identical to one with nothing to say."""
    return [
        (m.group(1), m.group(2).strip(), m.group(3).strip())
        for line in output.splitlines()
        if (m := CHECK.match(line))
    ]


def _assert_all_passed(output: str, what: str, app: str, platform: str) -> None:
    checks = _checks(output)
    assert checks, (
        f"{app}/{platform}: the {what} probe reported no checks at all. It "
        f"either failed to run or failed to reach the guest; either way the "
        f"absence of a FAIL is not evidence of a pass.\n{output[-2000:]}"
    )
    failed = [f"{label} ({detail})" for status, label, detail in checks if status == "FAIL"]
    assert not failed, (
        f"{app}/{platform}: {len(failed)} of {len(checks)} {what} checks failed:\n  - "
        + "\n  - ".join(failed)
    )


def pytest_generate_tests(metafunc):  # noqa: D401
    """Parametrise over the Windows apps for this platform."""
    if "win_app" not in metafunc.fixturenames:
        return
    p = metafunc.config.getoption("--platform")
    if not p:
        return
    with (REPO / "matrix-windows.yml").open() as fh:
        m = yaml.safe_load(fh)
    only = metafunc.config.getoption("--app")
    params = []
    for app in sorted(m.get("apps", {})):
        if only and app != only:
            continue
        if p not in m["apps"][app]:
            params.append(pytest.param(app, marks=pytest.mark.skip(
                reason=f"matrix-windows.yml does not declare {app} on {p}")))
        elif not (REPO / "profiles" / app / f"{p}-access.yml").is_file():
            params.append(pytest.param(app, marks=pytest.mark.skip(
                reason=f"no reviewed profile: profiles/{app}/{p}-access.yml")))
        else:
            params.append(pytest.param(app))
    metafunc.parametrize("win_app", params)


def _playbook(tmp: pathlib.Path, app: str, platform: str, group: str) -> pathlib.Path:
    """The apply playbook, generated per app exactly as the shell driver does.

    The pre_task creating the simulated team group is the apply-time entity the
    profile grants against -- the profile itself never names a person, which is
    the property the library claims and this proves.
    """
    play = tmp / f"{platform}-{app}.yml"
    play.write_text(f"""---
- hosts: win
  vars:
    declarative_access_windows_group: {group}
  vars_files:
    - {REPO}/profiles/{app}/{platform}-access.yml
  pre_tasks:
    - name: Simulated team group (the apply-time entity)
      ansible.windows.win_powershell:
        script: |
          $Ansible.Changed = $false
          if (-not (Get-LocalGroup -Name '{group}' -ErrorAction SilentlyContinue)) {{
            New-LocalGroup -Name '{group}' -Description 'dap verify' | Out-Null
            $Ansible.Changed = $true
          }}
  roles:
    - declarative_access_windows
""")
    return play


def test_windows_profile_verifies(
    win_guest, win_inventory, win_ps, win_app, platform, tmp_path, run_playbook,
    win_provenance, request
):
    app, group = win_app, f"{win_app}-team-sim"
    play = _playbook(tmp_path, app, platform, group)

    # --- APPLY ------------------------------------------------------------
    applied = run_playbook(win_inventory, play)
    assert applied.returncode == 0, (
        f"{app}/{platform}: applying the profile failed; every probe below "
        f"would be describing an unapplied host.\n{applied.stdout[-2500:]}"
    )

    # --- GRANTED ----------------------------------------------------------
    _assert_all_passed(win_ps(GRANTED, group, app), "granted", app, platform)

    # --- REVOKE, and prove it ---------------------------------------------
    # Runs whether or not the grant probes passed, matching the shell driver:
    # leaving a half-granted guest behind is worse than a red test.
    revoked_run = run_playbook(win_inventory, play, tags="cleanup")
    assert revoked_run.returncode == 0, (
        f"{app}/{platform}: the cleanup run failed. A grant that cannot be "
        f"revoked is a permanent grant.\n{revoked_run.stdout[-2500:]}"
    )
    _assert_all_passed(win_ps(REVOKED, group, app), "revoked", app, platform)

    if request.config.getoption("--stamp"):
        _stamp(app, platform, win_provenance)


def _stamp(app: str, platform: str, image: str) -> None:
    """Rewrite the profile's VERIFIED: header, only after every check passed.

    Two lines, because the single-line form runs past yamllint's 120-column
    limit; the image name is the identity that matters, so the OS caption the
    guest also reports is left out as redundant with it.
    """
    path = REPO / "profiles" / app / f"{platform}-access.yml"
    today = datetime.date.today().isoformat()
    text = path.read_text()
    new, n = re.subn(
        r"^# REVIEWED: (\S+)\s+VERIFIED: .*?\n(#\s+WMSVC.*?\n)?",
        f"# REVIEWED: \\1   VERIFIED: {today} (KVM {image},\n"
        f"#           WMSVC+SDDL+JEA applied, probed, revoked)\n",
        text, count=1, flags=re.MULTILINE | re.DOTALL,
    )
    if n:
        path.write_text(new)
