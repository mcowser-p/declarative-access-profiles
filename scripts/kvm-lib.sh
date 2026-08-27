#!/usr/bin/env bash
# kvm-lib.sh — shared KVM launch/teardown for the capture and verify drivers.
# The KVM counterpart of ec2-lib.sh, driving holy-qcow golden images instead
# of AMIs: same authoritative surface (authselect, real PAM/sshd, SELinux or
# AppArmor, systemd-logind) on our own CIS-hardened images, no cloud account.
#
# VMs are provisioned with OpenTofu through holy-qcow's tofu/modules/vm,
# consumed in place from a sibling checkout (HOLY_QCOW_SRC). The libvirt URI
# may be local (qemu:///system) or remote (qemu+ssh://user@host/system). NAT
# guests on a remote host are only reachable *from that host*, so guest ssh
# hops through it automatically (ProxyJump derived from the URI).
#
# Safety: throwaway domains all carry the dap- name prefix; teardown is an
# EXIT/INT/TERM trap that destroys via tofu AND reaps by prefix (launch runs
# in command substitution — a subshell — so on-disk workdirs plus the name
# prefix are the authoritative record, never a parent-scope array; the same
# lesson as ec2-lib's RunId tag). `sweep` reaps strays without any tfstate.
#
# Source this; then call kvm_launch / kvm_ssh / kvm_scp_back / kvm_teardown,
# or run the driver's `sweep` / `--dry-run`.
set -euo pipefail

: "${LIBVIRT_URI:=qemu:///system}"
: "${DAP_GOLDEN_POOL:=golden}"
: "${DAP_VM_POOL:=vmdisks}"
: "${KVM_SSH_USER:=ops}"

_KVMLIB_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${HOLY_QCOW_SRC:=$_KVMLIB_REPO/../md}"
# Which module inside HOLY_QCOW_SRC to consume. This harness is the only
# consumer that uses holy-qcow's modules IN PLACE rather than vendoring a frozen
# copy, so it is the only one that breaks the moment tofu/modules/vm is rewritten
# for a new provider major. Defaulting to the frozen legacy08 copy decouples the
# two: holy-qcow can rewrite at will and this harness keeps working, then flips
# by changing one variable. Keep the knob permanently -- it costs a line and buys
# the next migration for free.
: "${DAP_VM_MODULE:=tofu/modules/vm}"
# The provider constraint has to agree with the module, because the module ships
# its own required_providers block and tofu intersects every constraint in the
# graph: "~> 0.8.0, ~> 0.9.0" resolves to nothing and init fails outright.
# Derived rather than hardcoded so DAP_VM_MODULE stays a whole knob -- setting it
# back to legacy08 pins 0.8 again with no second edit.
# Read the provider constraint OUT OF the module rather than inferring it from
# the module's path.
#
# Inferring from the path assumed a module's contents match its name, and that
# assumption broke on 2026-08-27: holy-qcow on the KVM host had its uncommitted
# 0.9 migration discarded, so tofu/modules/vm went back to pinning ~> 0.8.0
# while still being called tofu/modules/vm. The harness kept deriving ~> 0.9.0
# from the name, and every launch died with
# "no available releases match the given constraints ~> 0.8.0, ~> 0.9.0".
#
# The module is the authority on which provider it needs. Asking it means the
# root module agrees by construction, whichever state the checkout is in.
_dap_module_pin() {
  local main="$1/main.tf" pin
  [ -f "$main" ] || return 1
  # Scoped to the libvirt block: the FIRST `version =` in a root-style main.tf
  # is terraform{ required_version }, and taking it yields the OpenTofu version
  # (">= 1.12.0") as a provider constraint -- which resolves to nothing.
  pin="$(grep -A3 'dmacvicar/libvirt' "$main" \
         | grep -oE 'version[[:space:]]*=[[:space:]]*"[^"]+"' | head -1 \
         | sed 's/.*"\(.*\)"/\1/')"
  [ -n "$pin" ] || return 1
  echo "$pin"
}
: "${DAP_PROVIDER_VERSION:=$(_dap_module_pin "$HOLY_QCOW_SRC/$DAP_VM_MODULE" \
    || case "$DAP_VM_MODULE" in *legacy08*) echo "~> 0.8.0" ;; *) echo "~> 0.9.0" ;; esac)}"
KVM_WORK_ROOT="$_KVMLIB_REPO/out/kvm"

# tofu and the mkisofs shim (exec'd by the libvirt provider for the seed
# ISO) may live in ~/.local/bin without being on a non-interactive PATH
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
TOFU="${TOFU:-$(command -v tofu || echo "$HOME/.local/bin/tofu")}"

log() { echo "[kvm] $*" >&2; }

# --- 0.9 + remote URI is not a supported combination ----------------------
# 0.9 dropped the `pool` argument on libvirt_cloudinit_disk. The seed ISO is now
# written to the filesystem of whatever machine runs tofu and is NOT uploaded
# through libvirt, so a remote qemu+ssh:// URI defines a domain whose seed does
# not exist on the hypervisor. Best case the domain refuses to start; worst case
# it boots with no cloud-init at all and the guest comes up with no ops user, no
# key and no hostname -- which looks like a slow boot, not a broken one, and the
# capture then blames ssh.
#
# The frozen legacy08 module is 0.8, which still uploads the ISO into a pool, so
# it remains the only module that works from a workstation. Refuse the
# combination rather than letting either failure happen.
kvm_assert_module_matches_uri() {
  case "$DAP_VM_MODULE:$LIBVIRT_URI" in
    *legacy08*) return 0 ;;
    *:qemu+ssh://*)
      log "FATAL: DAP_VM_MODULE=$DAP_VM_MODULE (libvirt 0.9) cannot drive a remote URI"
      log "  $LIBVIRT_URI"
      log "  0.9 writes the cloud-init seed to LOCAL /tmp and never uploads it, so"
      log "  the hypervisor cannot read it. Either:"
      log "    - run this harness ON the hypervisor with LIBVIRT_URI=qemu:///system, or"
      log "    - export DAP_VM_MODULE=tofu/modules/legacy08/vm to stay on 0.8 remotely."
      return 1 ;;
  esac
}

# --- guest ssh hop --------------------------------------------------------
# qemu+ssh://user@host/system → NAT guests live behind user@host. Derive the
# jump automatically; DAP_SSH_JUMP=none forces a direct connection.
kvm_jump() {
  if [ -n "${DAP_SSH_JUMP:-}" ]; then
    [ "$DAP_SSH_JUMP" = "none" ] || echo "$DAP_SSH_JUMP"
    return 0
  fi
  case "$LIBVIRT_URI" in
    qemu+ssh://*) echo "$LIBVIRT_URI" | sed 's|^qemu+ssh://||; s|/.*$||' ;;
  esac
}

_kvm_ssh_opts() {
  local jump; jump="$(kvm_jump)"
  echo "-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR${jump:+ -o ProxyJump=$jump}"
}

# --- image resolution (latest published build; never hardcode) ------------
kvm_slug_for() {
  case "$1" in
    almalinux-9) echo alma9 ;;
    almalinux-10) echo alma10 ;;
    ubuntu-24.04) echo ubuntu2404 ;;
    ubuntu-26.04) echo ubuntu2604 ;;
    amazonlinux-2023) echo al2023 ;;
    *) echo "unknown distro $1" >&2; return 1 ;;
  esac
}

# Latest <slug>-YYYYMMDD.qcow2 in the golden pool (dates sort lexically).
# Pin override: DAP_IMAGE_<slug> (e.g. DAP_IMAGE_alma9=alma9-20260822.qcow2).
kvm_image_for() {
  local distro="$1" slug pin vol
  slug="$(kvm_slug_for "$distro")" || return 1
  pin="$(eval "echo \${DAP_IMAGE_${slug}:-}")"
  if [ -n "$pin" ]; then echo "$pin"; return 0; fi
  vol="$(virsh -c "$LIBVIRT_URI" vol-list "$DAP_GOLDEN_POOL" 2>/dev/null \
    | awk '{print $1}' | grep -E "^${slug}-[0-9]{8}\.qcow2$" | sort | tail -1)"
  [ -n "$vol" ] || { log "FATAL: no ${slug}-*.qcow2 in pool $DAP_GOLDEN_POOL at $LIBVIRT_URI"; return 1; }
  echo "$vol"
}

# --- ephemeral keypair ----------------------------------------------------
DAP_KEY_DIR="" DAP_KEY_FILE=""

kvm_setup_key() {
  DAP_KEY_DIR="$(mktemp -d)"
  DAP_KEY_FILE="$DAP_KEY_DIR/dap-kvm"
  ssh-keygen -q -t ed25519 -N "" -C "dap-kvm-ephemeral" -f "$DAP_KEY_FILE"
  log "ephemeral key $DAP_KEY_FILE"
}

# --- launch one VM; echoes its IPv4; workdir is the teardown record -------
kvm_launch() {
  local distro="$1" vol name workdir ip
  kvm_assert_module_matches_uri || return 1
  vol="$(kvm_image_for "$distro")" || return 1
  name="dap-$(kvm_slug_for "$distro")"
  workdir="$KVM_WORK_ROOT/$distro"
  mkdir -p "$workdir"
  sed -e "s|@@VM_MODULE_SOURCE@@|$HOLY_QCOW_SRC/$DAP_VM_MODULE|" \
      -e "s|@@PROVIDER_VERSION@@|$DAP_PROVIDER_VERSION|" \
    "$_KVMLIB_REPO/scripts/kvm/main.tf.tmpl" > "$workdir/main.tf"

  log "launching $distro ($vol) as $name via $LIBVIRT_URI"
  "$TOFU" -chdir="$workdir" init -input=false >/dev/null
  "$TOFU" -chdir="$workdir" apply -auto-approve -input=false \
    -var "libvirt_uri=$LIBVIRT_URI" \
    -var "image=$vol" \
    -var "name=$name" \
    -var "ssh_authorized_keys=[\"$(cat "$DAP_KEY_FILE.pub")\"]" >/dev/null

  ip="$("$TOFU" -chdir="$workdir" output -raw ip 2>/dev/null || true)"
  # wait_for_lease can hand back nothing or an IPv6 link-local; the dnsmasq
  # lease table on the (possibly remote) host is authoritative — poll it.
  local i
  for i in $(seq 1 30); do
    case "$ip" in *.*.*.*) break ;; esac
    sleep 5
    ip="$(virsh -c "$LIBVIRT_URI" domifaddr "$name" --source lease 2>/dev/null \
      | awk '/ipv4/ {sub(/\/.*/,"",$4); print $4; exit}')"
  done
  case "$ip" in
    *.*.*.*) ;;
    *) log "FATAL: no IPv4 lease for $name after 150s"; return 1 ;;
  esac

  # wait for sshd
  local ok=0 opts; opts="$(_kvm_ssh_opts)"
  for i in $(seq 1 40); do
    # shellcheck disable=SC2086
    if ssh -i "$DAP_KEY_FILE" $opts -o ConnectTimeout=5 \
        "$KVM_SSH_USER@$ip" true 2>/dev/null; then ok=1; break; fi
    sleep 5
  done
  [ "$ok" = 1 ] || { log "FATAL: ssh never came up for $distro ($ip)"; return 1; }

  # provenance gate: the guest must self-report the image we asked for
  local image_name
  image_name="$(kvm_ssh "$ip" "$KVM_SSH_USER" \
    '. /etc/image-release 2>/dev/null && echo "$IMAGE_NAME"' | tail -1)"
  if [ "$image_name" != "${vol%.qcow2}" ]; then
    log "FATAL: guest reports IMAGE_NAME='$image_name', expected '${vol%.qcow2}'"
    return 1
  fi
  echo "$ip"
}

kvm_ssh() { local ip="$1" u="$2"; shift 2; local opts; opts="$(_kvm_ssh_opts)"
  # shellcheck disable=SC2086
  ssh -i "$DAP_KEY_FILE" $opts -o ConnectTimeout=10 "$u@$ip" "$@"; }
kvm_scp_to() { local src="$1" ip="$2" u="$3" dst="$4"; local opts; opts="$(_kvm_ssh_opts)"
  # shellcheck disable=SC2086
  scp -q -i "$DAP_KEY_FILE" $opts -r "$src" "$u@$ip:$dst"; }
kvm_scp_back() { local ip="$1" u="$2" src="$3" dst="$4"; local opts; opts="$(_kvm_ssh_opts)"
  # shellcheck disable=SC2086
  scp -q -i "$DAP_KEY_FILE" $opts -r "$u@$ip:$src" "$dst"; }

# destroy one distro's harness VM and drop its workdir; safe if none exists.
# Drivers call this between distros so a 5-distro sweep never holds more than
# one idle guest's RAM.
kvm_destroy_distro() {
  local workdir="$KVM_WORK_ROOT/$1"
  [ -f "$workdir/terraform.tfstate" ] || { rm -rf "$workdir"; return 0; }
  log "destroying $1"
  "$TOFU" -chdir="$workdir" destroy -auto-approve -input=false \
    -var "libvirt_uri=$LIBVIRT_URI" -var image=x -var name=x \
    -var 'ssh_authorized_keys=[]' >/dev/null 2>&1 || true
  rm -rf "$workdir"
}

# --- teardown (idempotent; safe as an EXIT trap) --------------------------
kvm_teardown() {
  set +e
  local workdir
  for workdir in "$KVM_WORK_ROOT"/*/; do
    [ -d "$workdir" ] || continue
    kvm_destroy_distro "$(basename "$workdir")"
  done
  kvm_sweep
  if [ -n "$DAP_KEY_DIR" ] && [ -d "$DAP_KEY_DIR" ]; then
    shred -u "$DAP_KEY_FILE" "$DAP_KEY_FILE.pub" 2>/dev/null
    rmdir "$DAP_KEY_DIR" 2>/dev/null
  fi
  log "teardown done"
  set -e
}

# scoped teardown for parallel per-distro driver runs: touches only the
# distros this run owns (the global kvm_teardown sweeps every dap-* guest
# and would reap a sibling run's VM). Drivers set DAP_TRAP_DISTROS before
# installing the trap.
DAP_TRAP_DISTROS=""
#
# Idempotent: the INT/TERM handlers installed by kvm_install_traps exit, which
# fires the EXIT trap as well, so without this guard the body runs twice --
# shredding an already-removed key dir and re-destroying distros.
_KVM_TORN_DOWN=0
kvm_teardown_scoped() {
  [ "$_KVM_TORN_DOWN" = 1 ] && return 0
  _KVM_TORN_DOWN=1
  set +e
  local d
  for d in $DAP_TRAP_DISTROS; do kvm_destroy_distro "$d"; done
  if [ -n "$DAP_KEY_DIR" ] && [ -d "$DAP_KEY_DIR" ]; then
    shred -u "$DAP_KEY_FILE" "$DAP_KEY_FILE.pub" 2>/dev/null
    rmdir "$DAP_KEY_DIR" 2>/dev/null
  fi
  set -e
}

# Install a driver's EXIT/INT/TERM traps.
#
# INT and TERM MUST exit, and that is the whole point of this helper. A bare
# `trap kvm_teardown_scoped EXIT INT TERM` runs the handler and then RESUMES the
# script, because a trap handler is not an exit path unless it says so. The
# result is worse than not trapping at all: the guest is destroyed and the run
# keeps going against a VM that no longer exists.
#
# Observed 2026-08-26 -- a SIGTERM partway through a verify run tore down
# ubuntu-24.04 and then reported the remaining five apps as FAIL, which reads as
# five broken access profiles rather than one interrupted run. Signal exits also
# have to be reported as signal exits (128+n), or a caller cannot tell an
# interrupted run from a genuine failure.
kvm_install_traps() {
  trap 'kvm_teardown_scoped' EXIT
  trap 'kvm_teardown_scoped; exit 130' INT
  trap 'kvm_teardown_scoped; exit 143' TERM
}

# --- sweep: reap any dap-* domain/volume, tfstate or not ------------------
kvm_sweep() {
  local d v
  for d in $(virsh -c "$LIBVIRT_URI" list --all --name 2>/dev/null | grep '^dap-'); do
    log "sweeping domain $d"
    virsh -c "$LIBVIRT_URI" destroy "$d" >/dev/null 2>&1
    virsh -c "$LIBVIRT_URI" undefine "$d" --nvram >/dev/null 2>&1
  done
  for v in $(virsh -c "$LIBVIRT_URI" vol-list "$DAP_VM_POOL" 2>/dev/null \
      | awk '{print $1}' | grep '^dap-'); do
    log "sweeping volume $v"
    virsh -c "$LIBVIRT_URI" vol-delete "$v" --pool "$DAP_VM_POOL" >/dev/null 2>&1
  done
  return 0
}

# --- dry-run: resolve every image + preflight, launch nothing -------------
kvm_dry_run() {
  log "DRY RUN — resolving images at $LIBVIRT_URI, launching nothing"
  local fail=0 d jump
  kvm_assert_module_matches_uri || fail=1
  [ -x "$TOFU" ] || command -v "$TOFU" >/dev/null 2>&1 || { log "MISSING: tofu ($TOFU)"; fail=1; }
  [ -d "$HOLY_QCOW_SRC/$DAP_VM_MODULE" ] \
    || { log "MISSING: HOLY_QCOW_SRC module dir $HOLY_QCOW_SRC/$DAP_VM_MODULE"; fail=1; }
  virsh -c "$LIBVIRT_URI" pool-info "$DAP_GOLDEN_POOL" >/dev/null 2>&1 \
    || { log "MISSING: pool $DAP_GOLDEN_POOL at $LIBVIRT_URI"; fail=1; }
  virsh -c "$LIBVIRT_URI" pool-info "$DAP_VM_POOL" >/dev/null 2>&1 \
    || { log "MISSING: pool $DAP_VM_POOL at $LIBVIRT_URI"; fail=1; }
  jump="$(kvm_jump)"
  [ -n "$jump" ] && log "guest ssh will ProxyJump via $jump"
  for d in $(python3 -c "
import yaml; m = yaml.safe_load(open('$_KVMLIB_REPO/matrix.yml'))
print(' '.join(m['distros']))"); do
    printf '  %-18s %s\n' "$d" "$(kvm_image_for "$d" 2>/dev/null || echo 'UNRESOLVED')" >&2
    kvm_image_for "$d" >/dev/null 2>&1 || fail=1
  done
  return $fail
}
