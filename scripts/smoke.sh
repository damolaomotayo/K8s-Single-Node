#!/usr/bin/env bash
# Health check of the cluster and the app. Ends with "All 15 checks passed."
set -uo pipefail
. "$(dirname "$0")/lib.sh"

PASS=0
TOTAL=0
check() { # LABEL COMMAND...
  local label="$1"; shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then ok "$label"; PASS=$((PASS + 1)); else fail "$label"; fi
}

server_running() { [ "$($DOCKER inspect -f '{{.State.Running}}' "$SERVER" 2>/dev/null)" = "true" ]; }
code_is() { [ "$(http_code "$1")" = "$2" ]; }
page_says_pod() { local out; out="$(curl -s -m 4 "$APP_URL/")"; grep -q "Served by Kubernetes pod" <<<"$out"; }
spreads_load() { local out; out="$(replicas_seen 30)"; [ "$(count_lines "$out")" -ge 2 ]; }
notes_log() { local out; out="$(curl -s -m 4 "$APP_URL/notes/starts.log")"; grep -q "started" <<<"$out"; }
pvc_bound() { local out; out="$(kd get pvc notes-data -o jsonpath='{.status.phase}')"; [ "$out" = "Bound" ]; }
three_endpoints() { local out; out="$(kd get endpoints web -o jsonpath='{.subsets[0].addresses[*].ip}')"; [ "$(wc -w <<<"$out" | tr -d ' ')" = "3" ]; }
rbac_ok() {
  local yes no
  yes="$(kc auth can-i list pods -n demo --as=system:serviceaccount:demo:viewer 2>/dev/null)"
  no="$(kc auth can-i delete pods -n demo --as=system:serviceaccount:demo:viewer 2>/dev/null || true)"
  [ "$yes" = "yes" ] && [ "$no" = "no" ]
}

log "Smoke test"
check "Docker daemon reachable"                      $DOCKER info
check "the k3s container is running"                 server_running
check "the Kubernetes API is ready"                  api_ready
check "the node is Ready"                            node_ready
check "coredns (DNS) is available"                   deploy_ready kube-system coredns
check "traefik (ingress) is available"               deploy_ready kube-system traefik
check "web: all 3 replicas available"                deploy_ready demo web
check "notes: available"                             deploy_ready demo notes
check "the service has 3 pod endpoints"              three_endpoints
check "the ingress answers on port 8080"             code_is "$APP_URL/healthz" 200
check "the page is served by a pod"                  page_says_pod
check "requests are spread over several pods"        spreads_load
check "the persistent volume is Bound"               pvc_bound
check "/notes serves the log on that volume"         notes_log
check "RBAC: the viewer can list pods but not delete" rbac_ok

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  printf '\033[1;32mAll %d checks passed.\033[0m\n' "$TOTAL"
else
  printf '\033[1;31m%d of %d checks passed.\033[0m See "If something goes wrong" in STEPS.md.\n' "$PASS" "$TOTAL" >&2
  exit 1
fi
IP="$(public_ip)"
echo "Open in your browser: http://${IP}:8080/"
