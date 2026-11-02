#!/usr/bin/env bash
# Run this BEFORE the demo. It pulls the k3s image, starts the cluster once (so Kubernetes' own images are
# downloaded into the cluster's cache), deploys the app once (so nginx is cached too), checks every manifest,
# and runs the tests, so any failure shows up now and not in front of an audience.
# The cluster is left running; stop it with ./scripts/destroy.sh only AFTER the demo.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

FAILS=0
check() { # LABEL COMMAND...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else fail "$label"; FAILS=$((FAILS + 1)); fi
}

pull_with_retry() { # IMAGE
  local i
  for i in 1 2 3; do
    $DOCKER pull "$1" >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}

# Docker Hub's /v2/ endpoint answers HTTP 401 (login required) when it is reachable.
# So 200 and 401 both mean "reachable". Do not add curl -f here.
hub_reachable() {
  local code
  code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' https://registry-1.docker.io/v2/ || true)"
  [ "$code" = "200" ] || [ "$code" = "401" ]
}
disk_ok()   { [ "$(df -BG --output=avail / | tail -n1 | tr -dc '0-9')" -ge 8 ]; }
mem_ok()    { [ "$(free -m | awk '/^Mem:/{print $2}')" -ge 3500 ]; }
port_free() { ! python3 -c 'import socket, sys; s = socket.socket(); s.settimeout(1); sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)' "$1"; }
privileged_ok() { $DOCKER run --rm --privileged "$NGINX_IMAGE" true; }
cluster_up() { $DC up -d && wait_until 240 api_ready && wait_until 240 node_ready; }
system_up() { wait_until 300 deploy_exists kube-system traefik && wait_until 300 system_ready; }
app_deploys() { apply_all && wait_app 240; }
all_tests() { PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests; }

log "System checks"
check "Docker daemon reachable"                  $DOCKER info
check "Docker Compose v2 installed"              $DC version
check "At least 8 GB free disk"                  disk_ok
check "At least 3.5 GB RAM"                      mem_ok
if [ "$($DOCKER ps -q --filter "name=^$SERVER\$" | wc -l)" -gt 0 ]; then
  ok "Cluster already running (port check skipped)"
else
  check "Port 8080 is free"                      port_free 8080
fi
check "Docker Hub reachable (HTTP 200 or 401)"   hub_reachable

log "Pulling images (up to 3 tries each)"
check "Pull $K3S_IMAGE"                          pull_with_retry "$K3S_IMAGE"
check "Pull $NGINX_IMAGE"                        pull_with_retry "$NGINX_IMAGE"
check "Privileged containers are allowed (k3s needs this)" privileged_ok

log "Cluster (the first start downloads Kubernetes' own images and can take a few minutes)"
check "k3s starts: API ready and node Ready"     cluster_up
check "coredns, traefik and storage are running" system_up
check "the app deploys and the ingress answers"  app_deploys

log "Tests"
check "Unit tests, manifest tests and repo tests" all_tests

echo
if [ "$FAILS" -eq 0 ]; then
  echo "Preflight passed. The cluster is running with the app deployed. Next: ./scripts/smoke.sh"
  exit 0
fi
echo "Preflight found $FAILS problem(s). See the troubleshooting table in STEPS.md." >&2
echo "Pull failed? Run 'sudo docker login' with a free Docker Hub account. Cluster failed? Run: $DOCKER logs --tail 60 $SERVER" >&2
exit 1
