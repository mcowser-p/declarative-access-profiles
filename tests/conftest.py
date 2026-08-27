"""Fixtures for the access-profile verification suite.

The division of labour is deliberate: **pytest fixtures own the lifecycle (when
things are torn down), kvm-lib.sh keeps owning the operations (how a guest is
launched)**. Nothing about tofu, lease polling or ProxyJump derivation is
reimplemented here -- those took real effort to get right and are still the only
copy. What moves is the *guarantee*.

That guarantee is the point of this file. The bash drivers installed
`trap kvm_teardown_scoped EXIT INT TERM`, and a trap handler is not an exit path
unless it says so, so a SIGTERM ran the teardown and then let the script carry on
against a guest that no longer existed -- reporting five apps as FAIL when the
run had simply been interrupted. A yield-fixture cannot do that: pytest unwinds
finalizers on exception, on KeyboardInterrupt and on normal exit, and the code
after `yield` is the only teardown path there is.

One VM per pytest process, one distro per process:

    pytest --distro almalinux-9

which matches how the labs are actually driven and parallelises the same way --
five processes, five distros, one guest each. The drivers already scope teardown
per distro, so concurrent runs do not reap each other.
"""
from __future__ import annotations

import os
import signal
import pathlib
import shutil
import subprocess

import pytest
import testinfra
import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
KVM_LIB = REPO / "scripts" / "kvm-lib.sh"


# --------------------------------------------------------------------------
# options
# --------------------------------------------------------------------------
def pytest_configure(config):  # noqa: D401
    """Make SIGTERM unwind fixtures instead of killing the process.

    pytest converts SIGINT into KeyboardInterrupt and unwinds finalizers, so
    Ctrl-C already tears the guest down. SIGTERM does not: Python's default
    disposition terminates immediately, no finalizers, guest left running and
    billing CPU until someone sweeps.

    The bash driver trapped TERM explicitly, so leaving it unhandled here would
    regress on the exact signal that caused the incident this port exists to
    prevent -- a SIGTERM mid-verify. Raising KeyboardInterrupt routes it into
    the same unwind path as Ctrl-C.

    SIGKILL remains unhandleable by anyone; `capture-matrix-kvm.sh sweep` is
    still the backstop for that, and always will be.
    """
    def _term(signum, frame):
        raise KeyboardInterrupt(f"signal {signum}")

    signal.signal(signal.SIGTERM, _term)


def pytest_addoption(parser):
    parser.addoption(
        "--distro",
        required=True,
        help="matrix distro to verify, e.g. almalinux-9. One per process.",
    )
    parser.addoption(
        "--app",
        default=None,
        help="verify only this app (default: every app with a reviewed profile)",
    )
    parser.addoption(
        "--stamp",
        action="store_true",
        help="rewrite each passing profile's VERIFIED: header with the guest's "
        "self-reported provenance. Off by default: stamping is a side effect, "
        "and a test run should not mutate the repo unless asked.",
    )


# --------------------------------------------------------------------------
# matrix
# --------------------------------------------------------------------------
@pytest.fixture(scope="session")
def matrix() -> dict:
    with (REPO / "matrix.yml").open() as fh:
        return yaml.safe_load(fh)


@pytest.fixture(scope="session")
def distro(request) -> str:
    d = request.config.getoption("--distro")
    with (REPO / "matrix.yml").open() as fh:
        known = yaml.safe_load(fh)["distros"]
    if d not in known:
        pytest.fail(f"unknown distro {d!r}; matrix.yml has {', '.join(known)}")
    return d


def pytest_generate_tests(metafunc):
    """Parametrise over every app in the matrix, not over the profiles on disk.

    Driving this from the profile directory -- which is what the bash driver
    does -- makes an absent cell indistinguishable from a cell that was never
    meant to exist. Both simply do not appear, and a run over amazonlinux-2023
    then reports "8 passed" as though 8 were the whole matrix.

    Every one of the 11 apps therefore produces a case, in one of three states:

      N/A          matrix.yml says the cell is impossible, and carries the
                   reason. Skipped WITH that reason attached, so the run shows
                   why rather than showing nothing.
      not reviewed the cell is possible but has no <distro>-access.yml yet.
                   Skipped, and distinctly -- an unreviewed cell is work
                   outstanding, not a decision already taken.
      live         run it.
    """
    if "app" not in metafunc.fixturenames:
        return
    d = metafunc.config.getoption("--distro")
    only = metafunc.config.getoption("--app")
    with (REPO / "matrix.yml").open() as fh:
        m = yaml.safe_load(fh)

    params = []
    for app in sorted(m["apps"]):
        if only and app != only:
            continue
        cell = m["apps"][app].get(d, {})
        if "na" in cell:
            mark = pytest.mark.skip(reason=f"N/A: {cell['na']}")
        elif not (REPO / "profiles" / app / f"{d}-access.yml").is_file():
            mark = pytest.mark.skip(reason=f"no reviewed profile: profiles/{app}/{d}-access.yml")
        else:
            params.append(pytest.param(app))
            continue
        params.append(pytest.param(app, marks=mark))
    metafunc.parametrize("app", params)


# --------------------------------------------------------------------------
# the guest
# --------------------------------------------------------------------------
def _bash(script: str, check: bool = True, key: str | None = None):
    """Run a snippet with kvm-lib.sh sourced, so launch/destroy/scp stay in one
    implementation rather than being re-expressed here.

    `key` is assigned AFTER the source, not passed through the environment:
    kvm-lib.sh opens with an unconditional `DAP_KEY_DIR="" DAP_KEY_FILE=""`, so
    an exported value is wiped the moment the library loads.
    """
    prelude = f'source "{KVM_LIB}"\n'
    if key:
        prelude += f'DAP_KEY_FILE={key!r}\nDAP_KEY_DIR="$(dirname {key!r})"\n'
    return subprocess.run(
        ["bash", "-c", prelude + script],
        capture_output=True,
        text=True,
        check=check,
        env=os.environ.copy(),
    )


@pytest.fixture(scope="session")
def guest(distro, request):
    """Launch one guest, yield (ip, key_path), always destroy it.

    kvm_setup_key and kvm_launch must share a shell -- the key path lives in
    DAP_KEY_FILE, which kvm_launch reads -- so they run in one invocation that
    prints both values back.
    """
    proc = _bash(
        f"""
        kvm_setup_key >&2
        printf 'KEY=%s\\n' "$DAP_KEY_FILE"
        ip="$(kvm_launch {distro})" || exit 1
        printf 'IP=%s\\n' "$ip"
        """
    )
    fields = dict(
        line.split("=", 1) for line in proc.stdout.splitlines() if "=" in line
    )
    ip, key = fields.get("IP"), fields.get("KEY")
    if not ip or not key:
        pytest.fail(f"launch produced no IP/KEY for {distro}\n{proc.stderr[-2000:]}")

    try:
        yield ip, key
    finally:
        # The only teardown path. Runs on pass, on failure, on --exitfirst, on
        # Ctrl-C, and on an exception inside another fixture.
        _bash(f'kvm_destroy_distro {distro} >&2', check=False)
        key_dir = pathlib.Path(key).parent
        if key_dir.exists() and key_dir.name.startswith("tmp"):
            shutil.rmtree(key_dir, ignore_errors=True)


@pytest.fixture(scope="session")
def ssh_prefix(guest) -> list[str]:
    """argv prefix for reaching the guest, ProxyJump included when the libvirt
    URI is remote (NAT guests are reachable only from the hypervisor)."""
    ip, key = guest
    jump = _bash("kvm_jump", check=False).stdout.strip()
    argv = [
        "ssh", "-i", key,
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
    ]
    if jump:
        argv += ["-o", f"ProxyJump={jump}"]
    return argv + [f'{os.environ.get("KVM_SSH_USER", "ops")}@{ip}']


@pytest.fixture(scope="session")
def host(guest, ssh_prefix):
    """testinfra Host for the guest.

    paramiko/ssh backends do not model ProxyJump, so this drives the system ssh
    client through testinfra's own connection string -- the same hop the rest of
    the harness uses, rather than a second one that could diverge.
    """
    ip, key = guest
    jump = _bash("kvm_jump", check=False).stdout.strip()
    user = os.environ.get("KVM_SSH_USER", "ops")
    opts = (
        "-o BatchMode=yes -o StrictHostKeyChecking=no "
        "-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
    )
    if jump:
        opts += f" -o ProxyJump={jump}"
    return testinfra.get_host(
        f"ssh://{user}@{ip}", ssh_identity_file=key, ssh_extra_args=opts
    )


@pytest.fixture(scope="session")
def bootstrapped(host, guest):
    """Guest-side prerequisites: the access collection, an ansible venv, acl.

    Session-scoped because it is the expensive part and is identical for every
    app on the guest -- the bash driver did the same, just without saying so.
    """
    ip, key = guest
    access_src = os.environ.get("ACCESS_SRC")
    if not access_src or not pathlib.Path(access_src).is_dir():
        pytest.fail(
            "ACCESS_SRC must point at an ansible-declarative-access checkout "
            f"(got {access_src!r})"
        )

    user = os.environ.get("KVM_SSH_USER", "ops")
    scp = _bash(
        f'kvm_scp_to {access_src!r} {ip!r} {user!r} /tmp/linux-access',
        check=False,
        key=key,
    )
    assert scp.returncode == 0, f"staging the collection failed:\n{scp.stderr[-1500:]}"

    res = host.run(
        """sudo bash -euc '
        mkdir -p /root/.dap-tmp; export TMPDIR=/root/.dap-tmp
        if command -v apt-get >/dev/null 2>&1; then
          export DEBIAN_FRONTEND=noninteractive
          apt-get update -qq && apt-get install -qq -y python3-venv python3-pip acl >/dev/null
        else
          dnf install -qy python3-pip acl >/dev/null
        fi
        python3 -m venv /opt/ans-venv
        /opt/ans-venv/bin/pip -q install ansible-core >/dev/null
        /opt/ans-venv/bin/ansible-galaxy collection install community.general ansible.posix >/dev/null 2>&1
        '"""
    )
    assert res.rc == 0, f"guest bootstrap failed:\n{res.stderr[-2000:]}"
    return True


@pytest.fixture(scope="session")
def provenance(host) -> str:
    """What the guest says it is, read from the guest rather than assumed.

    This string is what a VERIFIED: stamp records, so it must come from
    /etc/image-release plus a live getenforce/aa-enabled probe. An assumed value
    would make the stamp a restatement of the request instead of evidence.
    """
    res = host.run(
        """bash -s <<'PROBE'
. /etc/image-release 2>/dev/null
if command -v getenforce >/dev/null 2>&1; then
  mac="SELinux $(getenforce | tr '[:upper:]' '[:lower:]')"
elif command -v aa-enabled >/dev/null 2>&1 && aa-enabled >/dev/null 2>&1; then
  mac="AppArmor"
else
  mac="no MAC"
fi
if [ -n "${IMAGE_CIS_SCORE:-}" ]; then cis="CIS L1"; else cis="no CIS hardening"; fi
echo "KVM ${IMAGE_NAME:-unknown-image}, ${mac}, real PAM, ${cis}"
PROBE"""
    )
    assert res.rc == 0, f"provenance probe failed: {res.stderr}"
    return res.stdout.strip().splitlines()[-1]


@pytest.fixture(scope="session")
def put_profile(guest):
    """Stage one app's reviewed profile at /tmp/profile.yml on the guest.

    Per app rather than per session: the apply playbook reads a fixed path, which
    is the contract the reviewed profiles and the playbook already share.
    """
    ip, key = guest
    user = os.environ.get("KVM_SSH_USER", "ops")

    def _put(app: str, distro: str) -> None:
        src = REPO / "profiles" / app / f"{distro}-access.yml"
        res = _bash(
            f"kvm_scp_to {str(src)!r} {ip!r} {user!r} /tmp/profile.yml",
            check=False,
            key=key,
        )
        assert res.returncode == 0, f"staging {src.name} failed:\n{res.stderr[-800:]}"

    return _put
