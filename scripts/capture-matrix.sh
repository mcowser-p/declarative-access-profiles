#!/usr/bin/env bash
# capture-matrix.sh — batch-capture cairn footprints + raw access profiles
# for every (app, distro) cell in matrix.yml.
#
# Usage:  scripts/capture-matrix.sh [distro ...]     # default: all distros
# Env:    CAIRN_SRC   (required) path to a cairn checkout whose footprint
#                     command supports --access-vars (the script refuses to
#                     run otherwise).
#                     POST-RELEASE: drop CAIRN_SRC and install cairn from a
#                     release artifact instead.
#         DOCKER_HOST as needed (macOS Docker Desktop:
#                     unix://$HOME/.docker/run/docker.sock)
#
# Design (see cairn scripts/smoke-test.sh capture_footprint for the
# pattern's origin):
#   * PLAIN containers — capture diffs files; units are files; no systemd.
#   * parallel across distros, sequential apps inside each container
#   * re-baseline (`cairn files init --force`) before EVERY install so each
#     footprint isolates one package (+ its remaining dependency closure)
#   * skip-if-installed guard: a package pulled in earlier as a dependency
#     is skipped LOUDLY (recorded in the log, cell left empty)
#   * outputs land in the bind-mounted repo:
#       footprints/<distro>/footprint-<app>.json
#       profiles/<app>/<distro>-raw.yml     (byte-exact --access-vars output)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
: "${CAIRN_SRC:?set CAIRN_SRC to a cairn checkout (feature branch until merged)}"

# ---- preflight: the cairn tree must carry the access-vars exporter --------
grep -rq "access-vars" "$CAIRN_SRC/src/cairn/__main__.py" \
  || { echo "FATAL: $CAIRN_SRC has no --access-vars support (wrong branch?)" >&2; exit 2; }

DISTROS="${*:-$(python3 -c "
import yaml; m = yaml.safe_load(open('$REPO/matrix.yml'))
print(' '.join(m['distros']))")}"

mkdir -p "$REPO/out/logs"

run_distro() {
  local distro="$1"
  local image family
  image=$(python3 -c "
import yaml; m = yaml.safe_load(open('$REPO/matrix.yml'))
print(m['distros']['$distro']['image'])")
  family=$(python3 -c "
import yaml; m = yaml.safe_load(open('$REPO/matrix.yml'))
print(m['distros']['$distro']['family'])")
  local name="dap-capture-$distro"

  echo "[$distro] starting $image"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" \
    -v "$CAIRN_SRC":/opt/cairn-src:ro \
    -v "$REPO":/repo \
    "$image" sleep infinity >/dev/null

  # ---- bootstrap: python + cairn + footprint config ----------------------
  if [ "$family" = "debian" ]; then
    docker exec "$name" bash -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -qq -y python3-pip >/dev/null
      # PEP 668: ubuntu 24.04 is externally-managed; throwaway container
      pip3 -q install --break-system-packages /opt/cairn-src pyyaml'
  else
    docker exec "$name" bash -c '
      set -e
      dnf install -qy python3-pip >/dev/null
      pip3 -q install /opt/cairn-src pyyaml'
  fi
  docker exec "$name" bash -c '
    set -e
    mkdir -p /etc/cairn /var/lib/cairn
    cp /opt/cairn-src/packaging/cairn-footprint-linux.yaml /etc/cairn/footprint.yaml
    # keep our own machinery out of the diff (exclude: is mid-file — patch
    # with yaml, appending list items to the file tail is invalid YAML)
    python3 - <<PYEOF
import yaml
cfg = yaml.safe_load(open("/etc/cairn/footprint.yaml"))
cfg.setdefault("exclude", []).extend(["/var/lib/cairn/", "/etc/cairn/", "/repo/"])
yaml.safe_dump(cfg, open("/etc/cairn/footprint.yaml", "w"), sort_keys=False)
PYEOF'

  # ---- per-app capture loop ----------------------------------------------
  python3 -c "
import yaml, json
m = yaml.safe_load(open('$REPO/matrix.yml'))
for slug, cells in m['apps'].items():
    c = cells.get('$distro')
    if c is None:
        continue
    print(json.dumps({'slug': slug, **c}))" | while IFS= read -r cell; do
    slug=$(echo "$cell" | python3 -c "import json,sys; print(json.load(sys.stdin)['slug'])")
    na=$(echo "$cell" | python3 -c "import json,sys; print(json.load(sys.stdin).get('na',''))")
    if [ -n "$na" ]; then
      echo "[$distro/$slug] N/A: $na"
      continue
    fi
    pkg=$(echo "$cell" | python3 -c "import json,sys; print(json.load(sys.stdin)['package'])")
    appname=$(echo "$cell" | python3 -c "import json,sys; c=json.load(sys.stdin); print(c.get('app', c['slug']))")
    service=$(echo "$cell" | python3 -c "import json,sys; print(json.load(sys.stdin)['service'])")
    extra=$(echo "$cell" | python3 -c "import json,sys; print(' '.join(json.load(sys.stdin).get('extra', [])))")
    conflicts=$(echo "$cell" | python3 -c "import json,sys; print(' '.join(json.load(sys.stdin).get('conflicts', [])))")

    if [ "${SKIP_EXISTING:-0}" = "1" ] && [ -f "$REPO/footprints/$distro/footprint-$slug.json" ]; then
      echo "[$distro/$slug] already captured — skipping (SKIP_EXISTING=1)"
      continue
    fi

    mkdir -p "$REPO/footprints/$distro" "$REPO/profiles/$slug"

    echo "[$distro/$slug] baseline + install $pkg"
    docker exec -e PKG="$pkg" -e EXTRA="$extra" -e APPNAME="$appname" \
      -e SLUG="$slug" -e DISTRO="$distro" -e SERVICE="$service" \
      -e CONFLICTS="$conflicts" \
      "$name" bash -c '
      set -euo pipefail
      # remove conflicting packages from earlier captures BEFORE the
      # baseline, so the removal never appears in this footprint
      if [ -n "$CONFLICTS" ]; then
        if command -v apt-get >/dev/null 2>&1; then
          DEBIAN_FRONTEND=noninteractive apt-get remove -qq -y $CONFLICTS >/dev/null 2>&1 || true
        else
          dnf remove -qy $CONFLICTS >/dev/null 2>&1 || true
        fi
      fi
      cairn files init --config /etc/cairn/footprint.yaml --force >/tmp/init.log 2>&1

      # skip-if-installed guard (dependency of an earlier capture)
      if command -v apt-get >/dev/null 2>&1; then
        if dpkg -s "$PKG" >/dev/null 2>&1; then
          echo "SKIP: $PKG already present (dependency of an earlier capture)"; exit 3; fi
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -qq -y $PKG $EXTRA >/dev/null
      else
        if rpm -q "$PKG" >/dev/null 2>&1; then
          echo "SKIP: $PKG already present (dependency of an earlier capture)"; exit 3; fi
        dnf install -qy $PKG $EXTRA >/dev/null
      fi

      rc=0
      cairn footprint --config /etc/cairn/footprint.yaml --app "$APPNAME" \
        --report "/repo/footprints/$DISTRO/footprint-$SLUG.json" \
        --access-vars "/repo/profiles/$SLUG/$DISTRO-raw.yml" \
        >/tmp/footprint.log 2>&1 || rc=$?
      [ "$rc" -eq 1 ] || { cat /tmp/footprint.log; echo "FATAL: footprint exited $rc (expected 1)"; exit 1; }
      grep -q "$SERVICE" "/repo/footprints/$DISTRO/footprint-$SLUG.json" \
        || { echo "FATAL: $SERVICE missing from footprint"; exit 1; }
      echo "OK: $(wc -c < /repo/footprints/$DISTRO/footprint-$SLUG.json) bytes"
    ' || { s=$?; [ "$s" -eq 3 ] && continue || { echo "[$distro/$slug] FAILED"; exit 1; }; }
  done

  docker rm -f "$name" >/dev/null
  echo "[$distro] done"
}

pids=""
for d in $DISTROS; do
  run_distro "$d" > "$REPO/out/logs/capture-$d.log" 2>&1 &
  pids="$pids $!:$d"
done

fail=0
for pd in $pids; do
  pid="${pd%%:*}"; d="${pd##*:}"
  if wait "$pid"; then echo "PASS $d"; else echo "FAIL $d (see out/logs/capture-$d.log)"; fail=1; fi
done
exit $fail
