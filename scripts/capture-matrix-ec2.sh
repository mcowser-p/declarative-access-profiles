#!/usr/bin/env bash
# capture-matrix-ec2.sh — capture treadmark footprints + raw access profiles on
# REAL EC2 instances (one per distro; apps sequential with re-baseline).
# Authoritative substrate — captures the OS auth surface containers miss.
#
# Usage:
#   scripts/capture-matrix-ec2.sh --dry-run            # resolve AMIs + estimate
#   scripts/capture-matrix-ec2.sh sweep [--hours N]    # reap strays
#   scripts/capture-matrix-ec2.sh [distro ...]         # default: all distros
# Env:
#   TREADMARK_SRC (required) — treadmark checkout with --access-vars (feature branch
#             until merged). POST-MERGE: install treadmark from a release instead.
#   AWS_REGION (default us-west-2), DAP_ITYPE (default t3.small),
#   DAP_MAX_MINUTES (default 30, per-instance watchdog)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=ec2-lib.sh
source "$REPO/scripts/ec2-lib.sh"

[ "${1:-}" = "--dry-run" ] && { ec2_dry_run; exit 0; }
[ "${1:-}" = "sweep" ] && { shift; [ "${1:-}" = "--hours" ] && { ec2_sweep "$2"; exit 0; }; ec2_sweep; exit 0; }

: "${TREADMARK_SRC:?set TREADMARK_SRC to a treadmark checkout with --access-vars}"
grep -rq "access-vars" "$TREADMARK_SRC/src/treadmark/__main__.py" \
  || { echo "FATAL: $TREADMARK_SRC has no --access-vars (wrong branch?)" >&2; exit 2; }

DISTROS="${*:-almalinux-9 almalinux-10 ubuntu-24.04}"
trap ec2_teardown EXIT INT TERM
ec2_setup_sg_key

capture_one_distro() {
  local distro="$1" ip u start
  start=$(date +%s)
  ip="$(ec2_launch "$distro")" || return 1
  u="$(ec2_ssh_user "$distro")"
  log "$distro up at $ip ($u) — staging treadmark"

  ec2_scp_to "$TREADMARK_SRC" "$ip" "$u" "/tmp/treadmark-src"
  ec2_scp_to "$REPO/matrix.yml" "$ip" "$u" "/tmp/matrix.yml"

  # bootstrap treadmark in a venv (real host — no --break-system-packages)
  ec2_ssh "$ip" "$u" 'sudo bash -s' <<'BOOT'
set -e
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -qq -y python3-venv python3-pip >/dev/null
else
  dnf install -qy python3-pip >/dev/null
fi
python3 -m venv /opt/treadmark-venv
/opt/treadmark-venv/bin/pip -q install /tmp/treadmark-src pyyaml
mkdir -p /etc/treadmark /var/lib/treadmark
/opt/treadmark-venv/bin/python - <<PY
import yaml
c=yaml.safe_load(open("/tmp/treadmark-src/packaging/treadmark-footprint-linux.yaml"))
c.setdefault("exclude",[]).extend(["/var/lib/treadmark/","/etc/treadmark/","/opt/treadmark-venv/","/tmp/"])
yaml.safe_dump(c,open("/etc/treadmark/footprint.yaml","w"),sort_keys=False)
PY
BOOT

  # per-app capture loop (runs on the instance; re-baseline isolates each app)
  ec2_ssh "$ip" "$u" "sudo DISTRO=$distro bash -s" <<'CAP'
set -uo pipefail
TREADMARK=/opt/treadmark-venv/bin/treadmark
PY=/opt/treadmark-venv/bin/python
mkdir -p /tmp/out/footprints /tmp/out/profiles
$PY - <<'PYGEN' > /tmp/cells.txt
import yaml,json
m=yaml.safe_load(open("/tmp/matrix.yml"))
for slug,cells in m["apps"].items():
    c=cells.get("$DISTRO".strip()) if False else cells.get(__import__("os").environ["DISTRO"])
    if not c or "na" in c: continue
    print(json.dumps({"slug":slug,**c}))
PYGEN
while IFS= read -r cell; do
  slug=$($PY -c "import json,sys;print(json.loads(sys.argv[1])['slug'])" "$cell")
  pkg=$($PY -c "import json,sys;print(json.loads(sys.argv[1])['package'])" "$cell")
  app=$($PY -c "import json,sys;c=json.loads(sys.argv[1]);print(c.get('app',c['slug']))" "$cell")
  svc=$($PY -c "import json,sys;print(json.loads(sys.argv[1])['service'])" "$cell")
  extra=$($PY -c "import json,sys;print(' '.join(json.loads(sys.argv[1]).get('extra',[])))" "$cell")
  conflicts=$($PY -c "import json,sys;print(' '.join(json.loads(sys.argv[1]).get('conflicts',[])))" "$cell")
  echo "=== $slug ($pkg) ==="
  if [ -n "$conflicts" ]; then
    command -v apt-get >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get remove -qq -y $conflicts >/dev/null 2>&1 || dnf remove -qy $conflicts >/dev/null 2>&1 || true
  fi
  $TREADMARK files init --config /etc/treadmark/footprint.yaml --force >/dev/null 2>&1
  if command -v apt-get >/dev/null 2>&1; then
    dpkg -s "$pkg" >/dev/null 2>&1 && { echo "SKIP: $pkg already present"; continue; }
    DEBIAN_FRONTEND=noninteractive apt-get install -qq -y $pkg $extra >/dev/null 2>&1
  else
    rpm -q "$pkg" >/dev/null 2>&1 && { echo "SKIP: $pkg already present"; continue; }
    dnf install -qy $pkg $extra >/dev/null 2>&1
  fi
  rc=0
  $TREADMARK footprint --config /etc/treadmark/footprint.yaml --app "$app" \
    --report /tmp/out/footprints/footprint-$slug.json \
    --access-vars /tmp/out/profiles/$slug-raw.yml >/tmp/fp.log 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || { echo "FAIL: footprint rc=$rc"; cat /tmp/fp.log; continue; }
  grep -q "$svc" /tmp/out/footprints/footprint-$slug.json && echo "OK $(wc -c </tmp/out/footprints/footprint-$slug.json) bytes" || echo "WARN: $svc not in footprint"
done < /tmp/cells.txt
chmod -R a+r /tmp/out
CAP

  # bring artifacts back into the repo
  mkdir -p "$REPO/footprints/$distro"
  ec2_scp_back "$ip" "$u" "/tmp/out/footprints/*" "$REPO/footprints/$distro/"
  local tmpdir; tmpdir="$(mktemp -d)"
  ec2_scp_back "$ip" "$u" "/tmp/out/profiles/*" "$tmpdir/" || true
  for f in "$tmpdir"/*-raw.yml; do
    [ -e "$f" ] || continue
    local base slug; base="$(basename "$f")"; slug="${base%-raw.yml}"
    mkdir -p "$REPO/profiles/$slug"; cp "$f" "$REPO/profiles/$slug/$distro-raw.yml"
  done
  rm -rf "$tmpdir"

  ec2_charge $(( ($(date +%s)-start)/60 + 1 ))
  log "$distro capture complete"
}

fail=0
for d in $DISTROS; do capture_one_distro "$d" || { log "FAILED $d"; fail=1; }; done
exit $fail
