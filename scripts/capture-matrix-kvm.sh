#!/usr/bin/env bash
# capture-matrix-kvm.sh — capture treadmark footprints + raw access profiles on
# REAL KVM guests provisioned from holy-qcow golden images (one VM per distro;
# apps sequential with re-baseline). Authoritative substrate: our own images
# carry the OS auth surface (authselect, real /etc/pam.d/sshd, SELinux or
# AppArmor, systemd-logind, real sshd+PAM) plus the CIS L1 hardening the
# fleet actually runs.
#
# Usage:
#   scripts/capture-matrix-kvm.sh --dry-run           # resolve images + preflight
#   scripts/capture-matrix-kvm.sh sweep               # reap stray dap-* guests
#   scripts/capture-matrix-kvm.sh [distro ...]        # default: all matrix distros
# Env:
#   LIBVIRT_URI        qemu:///system (default) or qemu+ssh://user@host/system
#   HOLY_QCOW_SRC      holy-qcow checkout providing tofu/modules/vm (default ../md)
#   TREADMARK_VERSION  PyPI release installed on guests (default 0.11.0)
#   TREADMARK_SRC      optional dev checkout — overrides the PyPI install
#   DAP_IMAGE_<slug>   pin a specific golden volume (default: latest published)
#   DAP_ONLY_APP       capture only these matrix rows (space-separated)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=kvm-lib.sh
source "$REPO/scripts/kvm-lib.sh"

[ "${1:-}" = "--dry-run" ] && { kvm_dry_run; exit $?; }
[ "${1:-}" = "sweep" ] && { kvm_sweep; exit 0; }

: "${TREADMARK_VERSION:=0.11.0}"
if [ -n "${TREADMARK_SRC:-}" ]; then
  grep -rq "access-vars" "$TREADMARK_SRC/src/treadmark/__main__.py" \
    || { echo "FATAL: $TREADMARK_SRC has no --access-vars (wrong branch?)" >&2; exit 2; }
fi

DISTROS="${*:-$(python3 -c "
import yaml; print(' '.join(yaml.safe_load(open('$REPO/matrix.yml'))['distros']))")}"
DAP_TRAP_DISTROS="$DISTROS"
trap kvm_teardown_scoped EXIT INT TERM
kvm_setup_key

capture_one_distro() {
  local distro="$1" ip start
  start=$(date +%s)
  ip="$(kvm_launch "$distro")" || return 1
  log "$distro up at $ip ($KVM_SSH_USER) — staging treadmark"

  if [ -n "${TREADMARK_SRC:-}" ]; then
    kvm_scp_to "$TREADMARK_SRC" "$ip" "$KVM_SSH_USER" "/tmp/treadmark-src"
    kvm_scp_to "$TREADMARK_SRC/packaging/treadmark-footprint-linux.yaml" \
      "$ip" "$KVM_SSH_USER" "/tmp/dap-footprint.yaml"
  else
    kvm_scp_to "$REPO/scripts/treadmark-footprint-linux.yaml" \
      "$ip" "$KVM_SSH_USER" "/tmp/dap-footprint.yaml"
  fi
  kvm_scp_to "$REPO/matrix.yml" "$ip" "$KVM_SSH_USER" "/tmp/matrix.yml"

  # bootstrap treadmark in a venv. /opt is exec-ok on the CIS images (unlike
  # /tmp, which is noexec tmpfs); pip's staging goes under /root as well.
  kvm_ssh "$ip" "$KVM_SSH_USER" "sudo TM_VER=$TREADMARK_VERSION bash -s" <<'BOOT'
set -e
mkdir -p /root/.dap-tmp
export TMPDIR=/root/.dap-tmp
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -qq -y python3-venv python3-pip >/dev/null
else
  dnf install -qy python3-pip >/dev/null
fi
python3 -m venv /opt/treadmark-venv
if [ -d /tmp/treadmark-src ]; then
  /opt/treadmark-venv/bin/pip -q install /tmp/treadmark-src pyyaml
else
  /opt/treadmark-venv/bin/pip -q install "treadmark==$TM_VER" pyyaml
fi
mkdir -p /etc/treadmark /var/lib/treadmark
/opt/treadmark-venv/bin/python - <<PY
import yaml
c=yaml.safe_load(open("/tmp/dap-footprint.yaml"))
c.setdefault("exclude",[]).extend([
    "/var/lib/treadmark/","/etc/treadmark/","/opt/treadmark-venv/",
    "/tmp/","/root/.dap-tmp/"])
yaml.safe_dump(c,open("/etc/treadmark/footprint.yaml","w"),sort_keys=False)
PY
BOOT

  # per-app capture loop (runs on the guest; re-baseline isolates each app)
  kvm_ssh "$ip" "$KVM_SSH_USER" "sudo DISTRO=$distro ONLY_APP='${DAP_ONLY_APP:-}' bash -s" <<'CAP'
set -uo pipefail
TREADMARK=/opt/treadmark-venv/bin/treadmark
PY=/opt/treadmark-venv/bin/python
mkdir -p /tmp/out/footprints /tmp/out/profiles
$PY - <<'PYGEN' > /tmp/cells.txt
import yaml,json,os
m=yaml.safe_load(open("/tmp/matrix.yml"))
only=os.environ.get("ONLY_APP","").split()
for slug,cells in m["apps"].items():
    if only and slug not in only: continue
    c=cells.get(os.environ["DISTRO"])
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
  repos=$($PY -c "import json,sys;print(' '.join(json.loads(sys.argv[1]).get('repos',[])))" "$cell")
  echo "=== $slug ($pkg) ==="
  if [ -n "$conflicts" ]; then
    # purge, not remove: removing the mariadb-server META leaves the core/
    # common packages and /etc/mysql + /var/lib/mysql behind, and mysql's
    # postinst then silently skips data-dir init (defect found on 24.04)
    if command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get purge -qq -y $conflicts >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -qq -y >/dev/null 2>&1 || true
    else
      dnf remove -qy $conflicts >/dev/null 2>&1 || true
    fi
    # even a purge preserves a populated datadir (Debian debconf policy; rpm
    # keeps non-empty dirs) — clear the MySQL-family shared state so the
    # incoming server's postinst initializes from scratch (clean-host shape)
    case " $conflicts " in
      *mariadb*|*mysql*)
        rm -rf /var/lib/mysql /var/lib/mysql-files /var/lib/mysql-keyring \
               /var/lib/mariadb /etc/mysql /etc/my.cnf.d /etc/my.cnf ;;
    esac
  fi
  # extra repos (epel) are part of the environment, not the app: enable them
  # BEFORE the re-baseline so epel-release never pollutes the footprint.
  case " $repos " in *" epel "*)
    command -v dnf >/dev/null 2>&1 && dnf install -qy epel-release >/dev/null 2>&1 ;;
  esac
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
# a+rX not a+r: root's CIS umask 027 leaves these dirs 750, and without the
# search bit ops cannot readdir for the scp back
chmod -R a+rX /tmp/out
CAP

  # bring artifacts back into the repo (fatal if missing — a silent scp
  # failure here once masqueraded as a green run)
  mkdir -p "$REPO/footprints/$distro"
  kvm_scp_back "$ip" "$KVM_SSH_USER" "/tmp/out/footprints/*" "$REPO/footprints/$distro/" \
    || { log "FATAL: footprint copy-back failed for $distro"; kvm_destroy_distro "$distro"; return 1; }
  local tmpdir; tmpdir="$(mktemp -d)"
  kvm_scp_back "$ip" "$KVM_SSH_USER" "/tmp/out/profiles/*" "$tmpdir/" || true
  for f in "$tmpdir"/*-raw.yml; do
    [ -e "$f" ] || continue
    local base slug; base="$(basename "$f")"; slug="${base%-raw.yml}"
    mkdir -p "$REPO/profiles/$slug"; cp "$f" "$REPO/profiles/$slug/$distro-raw.yml"
  done
  rm -rf "$tmpdir"

  kvm_destroy_distro "$distro"
  log "$distro capture complete ($(( ($(date +%s)-start)/60 )) min)"
}

fail=0
for d in $DISTROS; do capture_one_distro "$d" || { log "FAILED $d"; fail=1; }; done
exit $fail
