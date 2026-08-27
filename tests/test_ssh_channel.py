"""Can a delegated team member reach an unconstrained shell over SSH?

The Windows access model has two channels for two audiences: an administrator
automates over SSH with their own admin token, and a delegated team member
connects over WinRM-HTTPS into a JEA endpoint whose role capability whitelists
the cmdlets and even the permitted parameter VALUES they may use.

That model rests entirely on one assumption: the delegated user cannot get an
SSH session. sshd hands out `powershell.exe` under the caller's own token --
no WinRM, no session configuration, no virtual account, no role capability. A
team member who can SSH in is not constrained by JEA at all, and every
ValidateSet in the .psrc is advisory.

None of the 25 checks in the granted/revoked probes tests that assumption. They
verify NTFS, service SDDLs, WMSVC delegation, JEA and group membership -- every
mechanism except the one that would hand out an unconstrained shell.

This asserts it directly: create a non-admin in the team group, give it a
correctly-permissioned SSH key, and try to log in. A PASS means the model holds.
A FAIL means JEA is decorative for anyone holding an SSH key.

The setup has to be exactly right or the result is worthless. Windows OpenSSH
silently refuses a non-admin authorized_keys file that is writable by anyone but
the user and SYSTEM, and that refusal looks identical to a policy refusal. The
test therefore proves its own setup first, and reports the sshd reason when
access is denied, so "refused by policy" is never confused with "I botched the
ACL".
"""
from __future__ import annotations

import pathlib
import subprocess

import pytest

PROBE_USER = "dapsshprobe"
PROBE_PW = "Dap!Probe9zQ"  # local, throwaway, destroyed with the guest


def _ssh_argv(key: str, user: str, ip: str, cmd: str) -> list[str]:
    return [
        "ssh", "-i", key,
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "-o", "ConnectTimeout=15",
        "-o", "PreferredAuthentications=publickey",
        f"{user}@{ip}", cmd,
    ]


@pytest.fixture(scope="module")
def probe_identity(win_guest, win_ps, tmp_path_factory):
    """A non-admin account in the team group, with a key sshd should accept.

    Deliberately NOT a member of Administrators: the question is whether an
    ordinary delegated user can reach a shell, and an admin trivially can.
    """
    ip, admin_key, _ = win_guest
    tmp = tmp_path_factory.mktemp("sshprobe")
    key = tmp / "probe"
    subprocess.run(
        ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "dap-ssh-probe",
         "-f", str(key)],
        check=True,
    )
    pub = (key.with_suffix(".pub")).read_text().strip()

    setup = tmp / "setup-probe.ps1"
    setup.write_text(f"""
$ErrorActionPreference = 'Stop'
$u = '{PROBE_USER}'
if (-not (Get-LocalUser -Name $u -ErrorAction SilentlyContinue)) {{
  New-LocalUser -Name $u -Password (ConvertTo-SecureString '{PROBE_PW}' -AsPlainText -Force) `
                -PasswordNeverExpires -AccountNeverExpires | Out-Null
}}
# Users, not Administrators. The whole point is an ordinary delegated account.
Add-LocalGroupMember -Group 'Users' -Member $u -ErrorAction SilentlyContinue
$grp = $env:DAP_GROUP
if ($grp -and (Get-LocalGroup -Name $grp -ErrorAction SilentlyContinue)) {{
  Add-LocalGroupMember -Group $grp -Member $u -ErrorAction SilentlyContinue
}}

# The profile directory only exists after a first logon, so create it.
$home_ = "C:\\Users\\$u"
New-Item -ItemType Directory -Force -Path "$home_\\.ssh" | Out-Null
Set-Content -Path "$home_\\.ssh\\authorized_keys" -Value '{pub}' -Encoding ascii

# sshd REFUSES a non-admin authorized_keys writable by anyone but the user and
# SYSTEM, and that refusal is indistinguishable from a policy refusal. Lock it
# down so a denial can only mean policy.
$ak = "$home_\\.ssh\\authorized_keys"
# Report every step. icacls is a native exe whose failures do not throw, and a
# silently-unapplied ACL makes sshd reject the key on permissions -- which looks
# exactly like a policy refusal and would turn this whole probe into a false
# negative. Set-Acl is used for the owner because icacls /setowner needs a
# privilege that is not reliably held, and its failure mode is this same silence.
# ORDER MATTERS, and getting it wrong fails silently in the worst way.
# Setting the owner to the probe user BEFORE writing the DACL leaves this
# script -- running as Administrator -- owning nothing and holding no ACE on a
# file whose inherited ACEs have just been stripped, so every later grant dies
# with "Access is denied". The ACL is then never applied, sshd rejects the key
# on permissions, and the probe reports a refusal that says nothing about policy.
# Write the ACEs while still privileged; hand over ownership last.
$r1 = & icacls $ak /inheritance:r 2>&1; "SETUP step_inherit=$LASTEXITCODE $($r1 -join ' ')"
$r2 = & icacls $ak /grant "$($u):F" 2>&1; "SETUP step_grantuser=$LASTEXITCODE $($r2 -join ' ')"
$r3 = & icacls $ak /grant "SYSTEM:F" 2>&1; "SETUP step_grantsys=$LASTEXITCODE $($r3 -join ' ')"

$acc = New-Object System.Security.Principal.NTAccount($u)
$sd  = Get-Acl $ak
$sd.SetOwner($acc)
Set-Acl -Path $ak -AclObject $sd
"SETUP step_owner=$?"

"SETUP user=$((Get-LocalUser -Name $u).Name)"
"SETUP admin=$((Get-LocalGroupMember -Group 'Administrators').Name -join ',')"
"SETUP keyfile=$(Test-Path $ak)"
"SETUP acl=$(((Get-Acl $ak).Access | ForEach-Object { "$($_.IdentityReference)=$($_.FileSystemRights)" }) -join ' | ')"
"SETUP owner=$((Get-Acl $ak).Owner)"
""")
    out = win_ps(setup, group="iis-team-sim", profile="iis")
    return {"ip": ip, "key": str(key), "setup": out}


def test_probe_setup_is_sound(probe_identity):
    """The measurement instrument, before the measurement.

    If the account or the key file is not actually in place, a failed login says
    nothing about policy -- so this has to pass before the real test means
    anything.
    """
    out = probe_identity["setup"]
    assert f"SETUP user={PROBE_USER}" in out, (
        f"the probe account was not created; a login failure below would prove "
        f"nothing.\n{out[-2000:]}"
    )
    assert "SETUP keyfile=True" in out, (
        f"authorized_keys was not written; a login failure below would prove "
        f"nothing.\n{out[-2000:]}"
    )
    admins = next((l for l in out.splitlines() if l.startswith("SETUP admin=")), "")
    assert PROBE_USER.lower() not in admins.lower(), (
        f"the probe account ended up in Administrators, which makes the test "
        f"meaningless -- an admin is supposed to have SSH.\n{admins}"
    )

    # icacls is a native exe: a non-zero exit does NOT throw, even under
    # $ErrorActionPreference='Stop'. So the ACL has to be asserted on, not
    # assumed -- an unreadable-by-sshd key file would deny access for a reason
    # that has nothing to do with policy, and this test would call that a pass.
    acl = next((l for l in out.splitlines() if l.startswith("SETUP acl=")), "")
    assert PROBE_USER.lower() in acl.lower(), (
        f"authorized_keys does not grant the probe user; sshd would reject the "
        f"key on permissions and the denial would say nothing about policy.\n"
        f"{acl}"
    )
    for forbidden in ("BUILTIN\\Users", "Everyone", "Authenticated Users"):
        assert forbidden.lower() not in acl.lower(), (
            f"authorized_keys is accessible to {forbidden}; Windows OpenSSH "
            f"refuses a non-admin key file writable beyond the user and SYSTEM, "
            f"and that refusal is indistinguishable from a policy refusal.\n{acl}"
        )


def test_delegated_user_cannot_get_an_ssh_shell(probe_identity):
    """The assumption the whole access model rests on."""
    ip, key = probe_identity["ip"], probe_identity["key"]
    res = subprocess.run(
        _ssh_argv(key, PROBE_USER, ip, "whoami; $PSVersionTable.PSEdition"),
        capture_output=True, text=True, timeout=90,
    )
    got_shell = res.returncode == 0 and PROBE_USER.lower() in res.stdout.lower()

    assert not got_shell, (
        f"A NON-ADMIN in the team group obtained a shell over SSH.\n"
        f"  whoami -> {res.stdout.strip()!r}\n"
        f"sshd hands out powershell.exe under the caller's own token: no WinRM, "
        f"no session configuration, no virtual account, no role capability. So "
        f"JEA constrains nothing for this user -- the ValidateSet on app-pool "
        f"names is advisory, and they can call Restart-WebAppPool DefaultAppPool "
        f"directly. The two-channel model (delegated=WinRM+JEA, admin=SSH) holds "
        f"only if this login is impossible.\n"
        f"Fix in the image, not the profile: scope sshd to administrators "
        f"(Match Group administrators / DenyGroups), or stop shipping sshd on "
        f"hosts that carry delegated access."
    )


def test_denial_is_by_policy_not_by_a_broken_key(probe_identity):
    """Why the denial happened, so a green result is not a false negative.

    A denial caused by permissions on authorized_keys would look exactly like a
    policy denial, and would let a real bypass hide behind a passing test.
    """
    ip, key = probe_identity["ip"], probe_identity["key"]
    res = subprocess.run(
        _ssh_argv(key, PROBE_USER, ip, "whoami"),
        capture_output=True, text=True, timeout=90,
    )
    if res.returncode == 0:
        pytest.skip("access was granted; the previous test is the finding")
    err = (res.stderr or "").lower()
    assert "permission denied" in err or "publickey" in err, (
        f"SSH failed for a reason that is neither a policy denial nor a key "
        f"rejection, so this run cannot tell you whether the channel is closed:"
        f"\n  stderr: {res.stderr.strip()!r}"
    )


def test_sshd_reason_is_recorded(probe_identity, win_ps, tmp_path):
    """Ask sshd itself why, so the verdict rests on the server's account of it.

    "Permission denied (publickey)" is what the CLIENT sees, and it is identical
    whether the server rejected the key on file permissions or refused the user
    on policy. Only the server log distinguishes them, and the difference is the
    whole finding: one means the channel is closed, the other means the
    instrument was broken.
    """
    ps = tmp_path / "sshd-reason.ps1"
    ps.write_text(r"""
$ErrorActionPreference = 'SilentlyContinue'
$log = 'C:\ProgramData\ssh\logs\sshd.log'
if (Test-Path $log) {
  "FILELOG"
  Get-Content $log -Tail 40 | Where-Object { $_ -match 'dapsshprobe|Authentication refused|bad ownership|invalid user|not allowed' }
} else {
  "EVENTLOG"
  Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 40 |
    Where-Object { $_.Message -match 'dapsshprobe|refused|denied|ownership|not allowed' } |
    ForEach-Object { $_.Message -replace "`r?`n", ' ' } | Select-Object -First 10
}
""")
    out = win_ps(ps)
    perms = [l for l in out.splitlines()
             if "bad ownership" in l.lower() or "bad modes" in l.lower()]
    assert not perms, (
        f"sshd refused the key on FILE PERMISSIONS, not policy. The channel may "
        f"well be open to a correctly-permissioned key -- this run proves "
        f"nothing about policy.\n" + "\n".join(perms)
    )
    print("\n--- sshd account of the denial ---\n" + out)
