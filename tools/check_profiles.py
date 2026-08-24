#!/usr/bin/env python3
"""check_profiles.py — the profile contract check (CI + pre-commit).

Validates every reviewed profile in profiles/<app>/<distro>-access.yml:
  * top-level keys are a subset of the exporter's vars contract
  * forbidden keys absent (entity and login are apply-time decisions)
  * declarative_access_profile_name matches the app directory
  * ownership entries are complete dicts
  * every reviewed file has its raw sibling; every raw file has its
    footprint JSON; every non-N/A matrix cell has all three artifacts

Windows profiles (matrix-windows.yml) are checked against their own
contract: `declarative_access_windows_*` keys, and a live-inventory
evidence file instead of the footprint -> raw -> reviewed chain. Feature
-channel installs cannot be captured by baseline diff at all (the payload
is pre-staged, so the diff shows zero services), so there is no raw
export to diff against — the review is against observed live state.

Exit 0 = clean; 1 = violations (listed); 2 = structural error.
"""
from __future__ import annotations

import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent

# The exporter's vars contract (docs/declarative-systemd-access.md in the
# mcowser_p.declarative_access collection). Keep in lockstep with treadmark's
# accessvars._KEY_ORDER.
ALLOWED = {
    "declarative_access_profile_name",
    "declarative_access_sudo",
    "declarative_access_services",
    "declarative_access_timers",
    "declarative_access_quadlets",
    "declarative_access_pam_group",
    "declarative_access_local_groups",
    "declarative_access_linger",
    "declarative_access_linger_users",
    "declarative_access_files_modify",
    "declarative_access_files_read",
    "declarative_access_files_exec",
    "declarative_access_folders_modify",
    "declarative_access_folders_read",
    "declarative_access_ownership",
    "declarative_access_commands",
}
FORBIDDEN = {
    "declarative_access_user",
    "declarative_access_group",
    "declarative_access_login",
}
OWNERSHIP_REQUIRED = {"path"}
OWNERSHIP_ALLOWED = {"path", "owner", "group", "mode", "recurse"}

# The Windows contract (declarative_access_windows role). Deliberately a
# separate namespace: NTFS DACLs replace rather than merge, and applying a
# Windows profile with the POSIX role (or vice versa) must be impossible by
# construction, not by convention.
WINDOWS_ALLOWED = {
    "declarative_access_windows_profile_name",
    # feature toggles — the primitives are opt-in, exactly as the POSIX role
    # gates sudo/pam_group/linger. A profile that lists sites but never sets
    # _wmsvc: true silently grants nothing.
    "declarative_access_windows_wmsvc",
    "declarative_access_windows_feature_delegation",
    "declarative_access_windows_service_sdset",
    "declarative_access_windows_jea",
    "declarative_access_windows_sites",          # IIS Manager delegation scope
    "declarative_access_windows_app_pools",      # recycle targets (JEA)
    "declarative_access_windows_services",       # sc.exe sdset grants
    "declarative_access_windows_delegation",     # feature-delegation sections
    "declarative_access_windows_folders_modify",  # icacls (OI)(CI) Modify
    "declarative_access_windows_folders_read",
    "declarative_access_windows_deny_pool_write",  # explicit deny for the pool identity
    "declarative_access_windows_cert_keys",      # private-key read grants
    "declarative_access_windows_event_channels",
    "declarative_access_windows_jea_functions",
    "declarative_access_windows_local_groups",
    "declarative_access_windows_ownership",
}
WINDOWS_FORBIDDEN = {
    "declarative_access_windows_user",
    "declarative_access_windows_group",
    "declarative_access_windows_admins",
}

errors: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def check_reviewed(path: Path, app: str) -> None:
    data = yaml.safe_load(path.read_text())
    if not isinstance(data, dict):
        err(f"{path}: not a mapping")
        return
    keys = set(data)
    for k in sorted(keys - ALLOWED):
        if k in FORBIDDEN:
            err(f"{path}: forbidden key {k} (entity/login are apply-time decisions)")
        else:
            err(f"{path}: unknown key {k} (not in the exporter contract)")
    name = data.get("declarative_access_profile_name")
    if name != app:
        err(f"{path}: profile_name {name!r} != app dir {app!r}")
    for i, own in enumerate(data.get("declarative_access_ownership") or []):
        if not isinstance(own, dict):
            err(f"{path}: ownership[{i}] not a dict")
            continue
        missing = OWNERSHIP_REQUIRED - set(own)
        extra = set(own) - OWNERSHIP_ALLOWED
        if missing:
            err(f"{path}: ownership[{i}] missing {sorted(missing)}")
        if extra:
            err(f"{path}: ownership[{i}] unknown fields {sorted(extra)}")


def check_reviewed_windows(path: Path, app: str) -> None:
    data = yaml.safe_load(path.read_text())
    if not isinstance(data, dict):
        err(f"{path}: not a mapping")
        return
    for k in sorted(set(data) - WINDOWS_ALLOWED):
        if k in WINDOWS_FORBIDDEN:
            err(f"{path}: forbidden key {k} (the entity is an apply-time decision)")
        elif k in ALLOWED:
            err(f"{path}: POSIX key {k} in a Windows profile "
                "(NTFS DACLs replace rather than merge — use the "
                "declarative_access_windows_* contract)")
        else:
            err(f"{path}: unknown key {k} (not in the Windows contract)")
    name = data.get("declarative_access_windows_profile_name")
    if name != app:
        err(f"{path}: profile_name {name!r} != app dir {app!r}")


def check_windows_matrix(known_apps: set[str]) -> None:
    """Validate the Windows half: matrix-windows.yml + its profiles."""
    mpath = REPO / "matrix-windows.yml"
    if not mpath.exists():
        return
    matrix = yaml.safe_load(mpath.read_text())
    platforms = list(matrix["platforms"])
    for app, cells in matrix["apps"].items():
        known_apps.add(app)
        for platform in platforms:
            cell = cells.get(platform)
            if cell is None:
                err(f"matrix-windows.yml: {app}/{platform} cell missing "
                    "(use an explicit na:)")
                continue
            reviewed = REPO / "profiles" / app / f"{platform}-access.yml"
            evidence = REPO / "evidence" / platform / f"inventory-{app}.json"
            if "na" in cell:
                for p in (reviewed, evidence):
                    if p.exists():
                        err(f"{p}: exists but matrix cell {app}/{platform} is N/A")
                continue
            if reviewed.exists():
                # evidence chain: live inventory -> reviewed (no raw export;
                # the Windows exporter is Linux-only by construction)
                if not evidence.exists():
                    err(f"{reviewed}: reviewed profile without its live-inventory "
                        f"evidence {evidence}")
                check_reviewed_windows(reviewed, app)


def main() -> int:
    matrix = yaml.safe_load((REPO / "matrix.yml").read_text())
    distros = list(matrix["distros"])

    for app, cells in matrix["apps"].items():
        for distro in distros:
            cell = cells.get(distro)
            if cell is None:
                err(f"matrix.yml: {app}/{distro} cell missing (use an explicit na:)")
                continue
            raw = REPO / "profiles" / app / f"{distro}-raw.yml"
            reviewed = REPO / "profiles" / app / f"{distro}-access.yml"
            fp = REPO / "footprints" / distro / f"footprint-{app}.json"
            if "na" in cell:
                for p in (raw, reviewed, fp):
                    if p.exists():
                        err(f"{p}: exists but matrix cell {app}/{distro} is N/A")
                continue
            # evidence chain: footprint -> raw -> reviewed
            if raw.exists() and not fp.exists():
                err(f"{raw}: raw profile without footprint {fp}")
            if reviewed.exists():
                if not raw.exists():
                    err(f"{reviewed}: reviewed profile without raw sibling {raw}")
                check_reviewed(reviewed, app)

    known_apps = set(matrix["apps"])
    check_windows_matrix(known_apps)

    # stray profile dirs in neither matrix
    prof_dir = REPO / "profiles"
    if prof_dir.exists():
        for d in sorted(p for p in prof_dir.iterdir() if p.is_dir()):
            if d.name not in known_apps:
                err(f"{d}: profile dir in neither matrix.yml nor matrix-windows.yml")

    if errors:
        print(f"check_profiles: {len(errors)} violation(s)")
        for e in errors:
            print(f"  {e}")
        return 1
    print("check_profiles: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
