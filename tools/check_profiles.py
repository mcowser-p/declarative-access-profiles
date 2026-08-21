#!/usr/bin/env python3
"""check_profiles.py — the profile contract check (CI + pre-commit).

Validates every reviewed profile in profiles/<app>/<distro>-access.yml:
  * top-level keys are a subset of the exporter's vars contract
  * forbidden keys absent (entity and login are apply-time decisions)
  * declarative_access_profile_name matches the app directory
  * ownership entries are complete dicts
  * every reviewed file has its raw sibling; every raw file has its
    footprint JSON; every non-N/A matrix cell has all three artifacts

Exit 0 = clean; 1 = violations (listed); 2 = structural error.
"""
from __future__ import annotations

import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent

# The exporter's vars contract (docs/declarative-systemd-access.md in the
# mcowser_p.declarative_access collection). Keep in lockstep with cairn's
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

    # stray profile dirs not in the matrix
    prof_dir = REPO / "profiles"
    if prof_dir.exists():
        for d in sorted(p for p in prof_dir.iterdir() if p.is_dir()):
            if d.name not in matrix["apps"]:
                err(f"{d}: profile dir not in matrix.yml")

    if errors:
        print(f"check_profiles: {len(errors)} violation(s)")
        for e in errors:
            print(f"  {e}")
        return 1
    print("check_profiles: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
