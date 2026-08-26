#!/usr/bin/env bash
# winget-recon.sh — probe winget package availability on a Windows Server
# guest, to decide which apps are worth treadmarking into the corpus.
#
# READ-ONLY on the guest: `winget show`, never `winget install`.
#
# Usage:
#   scripts/winget-recon.sh --dry-run
#   scripts/winget-recon.sh sweep                      # reap stray guests
#   scripts/winget-recon.sh [platform]                 # default: windows-2025
#     platforms: windows-2025 | windows-2022 | windows-2022-desktop
# Env:
#   LIBVIRT_URI   qemu:///system or qemu+ssh://user@host/system
#   HOLY_QCOW_SRC holy-qcow checkout (default ../md)
#   DAP_KEEP_VM=1 leave the guest running afterwards
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=windows-lib.sh
source "$REPO/scripts/windows-lib.sh"

[ "${1:-}" = "--dry-run" ] && { win_dry_run; exit $?; }
[ "${1:-}" = "sweep" ] && { win_sweep; exit 0; }

# Desktop is the default corpus platform. Server 2025 Core cannot run winget
# over SSH: the App Installer is an MSIX package that registers per-user at
# INTERACTIVE logon, C:\Program Files\WindowsApps is ACL'd to TrustedInstaller
# so even an elevated admin cannot enumerate it, and the DISM-backed Appx
# cmdlets throw a COMException on that image — so the documented recovery path
# is itself unavailable there. Desktop Experience carries the shell stack that
# makes Appx registration behave normally.
PLATFORM="${1:-windows-2022-desktop}"
mkdir -p "$REPO/evidence/$PLATFORM" "$REPO/out"
win_install_traps
win_setup_creds

# The probe reads JSON; the candidate list is YAML so it stays commentable.
CAND_JSON="$REPO/out/winget-candidates.json"
python3 - "$REPO/scripts/winget-candidates.yml" "$CAND_JSON" <<'PY'
import json, sys, yaml
src, dst = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(src))
flat = []
for cat, body in doc["categories"].items():
    for p in body["packages"]:
        flat.append({"id": p["id"], "category": cat,
                     "service": bool(p.get("service")),
                     "uncertain": bool(p.get("uncertain")),
                     "control": bool(p.get("control"))})
json.dump(flat, open(dst, "w"), indent=1)
print(f"{len(flat)} candidates across {len(doc['categories'])} categories")
PY

ip="$(win_launch "$PLATFORM")" || exit 1
log "$PLATFORM up at $ip — staging candidate list and probing winget"

# stage the list beside the script; the probe resolves it via $PSScriptRoot
win_scp_to "$CAND_JSON" "$ip" 'C:/Windows/Temp/winget-candidates.json'

out="$REPO/evidence/$PLATFORM/winget-recon.json"
raw="$REPO/out/$PLATFORM-recon.raw"
win_run_ps1 "$ip" "$REPO/scripts/winget-recon.ps1" > "$raw" 2>"$REPO/out/$PLATFORM-recon.err" || true

if [ ! -s "$raw" ]; then
  log "FATAL: probe produced no output — stderr:"; tail -20 "$REPO/out/$PLATFORM-recon.err" >&2
  exit 1
fi

# Belt and braces: the probe sends diagnostics to stderr, but a single stray
# stdout line would otherwise make the evidence file unparseable. Keep only
# from the first '{' onward, and strip CR (PowerShell emits CRLF over SSH).
python3 - "$raw" "$out" <<'PY'
import sys
txt = open(sys.argv[1], encoding='utf-8-sig', errors='replace').read().replace('\r', '')
i = txt.find('{')
if i < 0:
    sys.stderr.write("no JSON object in probe output\n"); sys.exit(1)
if i > 0:
    sys.stderr.write(f"[warn] discarded {i} bytes of non-JSON stdout before the object\n")
open(sys.argv[2], 'w').write(txt[i:])
PY

python3 - "$out" "$PLATFORM" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"\n=== winget recon: {sys.argv[2]} ({d.get('image')}) ===")
print(f"os              : {d.get('os')}")
print(f"winget available: {d.get('winget_available')}")
print(f"bootstrap       : {d.get('bootstrap_note')}")
print(f"winget version  : {d.get('winget_version')}")
pkgs = d.get("packages") or []
if not pkgs:
    print("\nNo packages probed — winget was unavailable on this platform.")
    sys.exit(0)
found = [p for p in pkgs if p["found"] is True]
missing = [p for p in pkgs if p["found"] is False]
unknown = [p for p in pkgs if p["found"] not in (True, False)]
print(f"\nfound {len(found)} / probed {len(pkgs)}   missing {len(missing)}   unknown {len(unknown)}")
ctl = [p for p in pkgs if p.get("control")]
for c in ctl:
    verdict = "OK (probe distinguishes)" if c["found"] is False else "BROKEN — control matched!"
    print(f"negative control: {c['id']} -> found={c['found']}  {verdict}")
print("\nservice-installing and available (capture these first):")
for p in sorted(found, key=lambda x: (x["category"], x["id"])):
    if p["expects_service"]:
        print(f"  {p['category']:15} {p['id']:42} {p.get('version') or '?':14} {p.get('installer_type') or ''}")
PY
