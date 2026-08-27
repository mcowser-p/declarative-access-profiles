"""Access-profile verification, one guest per distro, one case per app.

A port of scripts/_verify-remote.sh, which hand-rolled a test runner: a `fail=0`
accumulator, `echo "OK"/"FAIL"`, and an exit code. That worked, but it could only
ever answer "did the run exit non-zero", and two things this repo cares about are
invisible at that resolution:

  * WHY a cell is absent. matrix.yml records N/A as a decision with a reason;
    a bash loop that skips those cells silently reports full coverage over a
    smaller matrix. Here they are skips carrying the reason.

  * WHETHER THE APP WAS ACTUALLY UP. A capture once returned OK for
    mysql/ubuntu-24.04 while silently missing pam_group, the mysql group and
    all three ownership entries -- mysqld had not finished initialising and
    nothing noticed, because exit status cannot see content. test_profile_paths_exist
    below is that missing assertion.

The flow per app matches the original exactly: purge conflicts, install, create
the probe principals, APPLY the reviewed profile with the real playbook, probe
allow/deny/behavioural, then REVOKE with --tags cleanup and assert it is gone.
It is one test per app rather than one per probe because apply/revoke bracket the
probes -- splitting them would either re-apply per probe or leave the guest in a
half-applied state between tests.
"""
from __future__ import annotations

import datetime
import pathlib
import re
import shlex

import pytest
import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
# The collection is staged at /tmp/linux-access, and playbook 5 imports the
# declarative_access role by bare name -- so the roles path has to be exported
# with every invocation, exactly as _verify-remote.sh did at the top of the
# script. Without it the apply dies with "role not found", which is the same
# shape as a genuine profile failure.
ROLES = "ANSIBLE_ROLES_PATH=/tmp/linux-access/roles"
ANS = "/opt/ans-venv/bin/ansible-playbook"
PLAYBOOK = "/tmp/linux-access/playbooks/5_apply_access_profile.yml"


def _cell(matrix, app, distro) -> dict:
    return matrix["apps"][app][distro]


def _profile(app, distro) -> dict:
    with (REPO / "profiles" / app / f"{distro}-access.yml").open() as fh:
        return yaml.safe_load(fh)


def _sudo(host, cmd, **kw):
    """Run a script as root on the guest.

    shlex.quote, NOT {cmd!r}. repr() escapes a newline to a literal backslash-n,
    and bash inside single quotes takes that literally -- so every multi-line
    block silently became one nonsense line and never ran. The install appeared
    to succeed because the failure was swallowed by `|| true`, and the first
    thing to notice was the paths-exist assertion reporting an application that
    was never installed.
    """
    return host.run(f"sudo bash -c {shlex.quote(cmd)}", **kw)


# --------------------------------------------------------------------------
def test_profile_verifies(host, bootstrapped, provenance, put_profile, app, distro, matrix, request):
    cell = _cell(matrix, app, distro)
    pkg = cell.get("package", "")
    conflicts = " ".join(cell.get("conflicts", []) or [])
    repos = cell.get("repos", []) or []
    profile = _profile(app, distro)
    team = f"{app}-team-sim"
    put_profile(app, distro)   # the apply playbook reads a fixed /tmp/profile.yml

    # --- repos ------------------------------------------------------------
    if "epel" in repos:
        _sudo(host, "dnf install -qy epel-release >/dev/null 2>&1 || true")

    # --- conflicting packages --------------------------------------------
    # mysql-server and mariadb-server cannot coexist. Removing the meta alone
    # strands the core packages and their conffiles, and the incoming package's
    # postinst then skips data-dir initialisation -- so the install "succeeds"
    # and every probe afterwards lies. Purge, then clear the shared datadir,
    # because even a purge preserves a populated one.
    if conflicts:
        _sudo(host, f"""
            if command -v apt-get >/dev/null 2>&1; then
              DEBIAN_FRONTEND=noninteractive apt-get purge -qq -y {conflicts} >/dev/null 2>&1 || true
              DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -qq -y >/dev/null 2>&1 || true
            else
              dnf remove -qy {conflicts} >/dev/null 2>&1 || true
            fi
            rm -rf /var/lib/mysql /var/lib/mysql-files /var/lib/mysql-keyring \\
                   /var/lib/mariadb /etc/mysql /etc/my.cnf.d /etc/my.cnf
        """)

    # --- install ----------------------------------------------------------
    if pkg:
        _sudo(host, f"""
            if command -v apt-get >/dev/null 2>&1; then
              DEBIAN_FRONTEND=noninteractive apt-get install -qq -y {pkg} >/dev/null 2>&1 || true
            else
              dnf install -qy {pkg} >/dev/null 2>&1 || true
            fi
        """)

    # --- probe principals -------------------------------------------------
    # Users persist across apps on this guest, so ADD them to each app's team
    # group; creating them only in the first app's group makes every later app
    # fail for the wrong reason. pamuser's '*' password means no password, which
    # is not the same as locked -- a locked account cannot log in at all and the
    # behavioural probe would be testing nothing.
    _sudo(host, f"""
        groupadd {team} 2>/dev/null || true
        id appdev  >/dev/null 2>&1 || useradd -m appdev
        id pamuser >/dev/null 2>&1 || useradd -m -p '*' pamuser
        usermod -aG {team} appdev
        usermod -aG {team} pamuser
    """)

    # --- the app must actually be up before anything is asserted about it --
    # This is the check the shell probe did not have. Without it a half-installed
    # service still yields a green run, and the profile gets a VERIFIED stamp it
    # has not earned.
    missing = _profile_paths_missing(host, profile)
    assert not missing, (
        f"{app}/{distro}: the reviewed profile names paths that do not exist on "
        f"the guest after installing {pkg!r}: {missing}. The package installed "
        f"but did not finish initialising, so anything asserted below would be "
        f"describing an application that is not up."
    )

    # --- APPLY ------------------------------------------------------------
    apply = _sudo(host, (
        f"{ROLES} {ANS} -i localhost, -c local {PLAYBOOK} "
        f"-e @/tmp/profile.yml -e group_name={team} "
        f"-e declarative_access_sudo_nopasswd=true"
    ), )
    assert apply.rc == 0 and "failed=0" in apply.stdout, (
        f"{app}/{distro}: applying the profile failed. A silent failed=1 makes "
        f"every probe below lie.\n{_recap(apply.stdout)}\n{apply.stderr[-1500:]}"
    )

    # --- DENY: a foreign unit must be refused ------------------------------
    denied = _sudo(host, (
        "sudo -u appdev sudo -n systemctl restart sshd.service >/dev/null 2>&1 || "
        "sudo -u appdev sudo -n systemctl restart ssh.service  >/dev/null 2>&1"
    ))
    assert denied.rc != 0, (
        f"{app}/{distro}: appdev restarted sshd. The profile grants rights over "
        f"one application; reaching a foreign unit is the failure this whole "
        f"library exists to prevent."
    )

    # --- ALLOW: the app's own config dir must be writable -------------------
    folders = profile.get("declarative_access_folders_modify") or []
    if folders:
        conf = folders[0]
        if host.file(conf).exists:
            wrote = _sudo(host, f"sudo -u appdev bash -c \"touch '{conf}/.probe' && rm -f '{conf}/.probe'\"")
            assert wrote.rc == 0, (
                f"{app}/{distro}: appdev cannot write {conf}, which the profile "
                f"grants. Rights that do not work are worse than no rights: the "
                f"reviewer believes the grant landed."
            )

    # --- BEHAVIOURAL: pam_group at a real sshd login ------------------------
    # Reported, never fatal -- matching the shell probe, which emitted WARN here.
    # The PAM stack varies with authselect and this probe is the first thing to
    # notice, but it is not the profile's contract.
    if profile.get("declarative_access_pam_group"):
        groups = profile.get("declarative_access_local_groups") or []
        if groups:
            ids = _pam_group_login(host, team, groups[0])
            if groups[0] not in ids:
                request.node.add_report_section(
                    "call", "behavioural",
                    f"WARN {app}/{distro}: '{groups[0]}' absent from the sshd "
                    f"session id ({ids.strip()}) -- check the authselect/PAM stack.",
                )

    # --- REVOKE ------------------------------------------------------------
    revoke = _sudo(host, (
        f"{ROLES} {ANS} -i localhost, -c local {PLAYBOOK} "
        f"-e @/tmp/profile.yml -e group_name={team} --tags cleanup --skip-tags login"
    ))
    assert revoke.rc == 0, f"{app}/{distro}: revoke run failed\n{_recap(revoke.stdout)}"

    survived = _sudo(host, f"ls /etc/sudoers.d/ | grep -q {app}")
    assert survived.rc != 0, (
        f"{app}/{distro}: a sudoers fragment survived --tags cleanup. A grant "
        f"that cannot be revoked is a permanent grant."
    )

    if request.config.getoption("--stamp"):
        _stamp(app, distro, provenance)


# --------------------------------------------------------------------------
def _profile_paths_missing(host, profile) -> list[str]:
    """Paths the reviewed profile names that are absent on the guest.

    Only ownership entries and folders are checked -- those are created by the
    package's own postinst/initialisation, so their absence means the app did
    not finish coming up.
    """
    wanted = [e["path"] for e in (profile.get("declarative_access_ownership") or [])]
    wanted += list(profile.get("declarative_access_folders_modify") or [])
    return [p for p in dict.fromkeys(wanted) if not host.file(p).exists]


def _pam_group_login(host, team: str, group: str) -> str:
    """id(1) from a real sshd session, not a simulated one -- pam_group grants
    at login, so nothing short of an actual login proves it."""
    # ssh-keygen must never prompt: on a re-run it asks "Overwrite?" and would
    # read the answer from whatever is on stdin.
    out = _sudo(host, f"""
        [ -f /root/.probe_key ] || ssh-keygen -q -t ed25519 -N '' -f /root/.probe_key </dev/null >/dev/null 2>&1
        mkdir -p /home/pamuser/.ssh
        cp /root/.probe_key.pub /home/pamuser/.ssh/authorized_keys
        chown -R pamuser:{team} /home/pamuser/.ssh
        chmod 700 /home/pamuser/.ssh; chmod 600 /home/pamuser/.ssh/authorized_keys
        ssh -i /root/.probe_key -o BatchMode=yes -o StrictHostKeyChecking=no \\
            -o UserKnownHostsFile=/dev/null pamuser@127.0.0.1 id 2>/dev/null || true
    """)
    return out.stdout


def _recap(stdout: str) -> str:
    lines = stdout.splitlines()
    for i, line in enumerate(lines):
        if "PLAY RECAP" in line:
            return "\n".join(lines[i : i + 3])
    return stdout[-800:]


def _stamp(app: str, distro: str, provenance: str) -> None:
    """Rewrite the profile's VERIFIED: header in place.

    Only ever called after every assertion above has passed, and only under
    --stamp. The date is the run's, the parenthesised text is the guest's own
    report -- a stamp asserting anything the guest did not say would be a
    restatement of the request rather than evidence.
    """
    path = REPO / "profiles" / app / f"{distro}-access.yml"
    today = datetime.date.today().isoformat()
    text = path.read_text()
    new, n = re.subn(
        r"^(# REVIEWED: \S+)\s+VERIFIED: .*$",
        rf"\1   VERIFIED: {today} ({provenance})",
        text,
        count=1,
        flags=re.MULTILINE,
    )
    if n:
        path.write_text(new)
