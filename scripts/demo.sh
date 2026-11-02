#!/usr/bin/env bash
# Scripted demo. Usage: ./scripts/demo.sh [deploy|selfheal|scale|rolling|config|persistence|rbac|all]
# Every scenario starts from a freshly created "demo" namespace and checks its own result.
# Keep http://<EC2-PUBLIC-IP>:8080/ open in a browser while it runs and refresh it.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
server_exists() { $DOCKER inspect "$SERVER" >/dev/null 2>&1; }
ns_absent() { ! kc get ns demo >/dev/null 2>&1; }
server_exists || die "The cluster is not running. Run ./scripts/up.sh first."

FAILURES=0
assert() { # LABEL COMMAND...
  local label="$1"; shift
  if "$@"; then ok "$label"; else fail "$label"; FAILURES=$((FAILURES + 1)); fi
}
finish() {
  if [ "$FAILURES" -eq 0 ]; then printf '\n\033[1;32mPASS\033[0m  %s\n\n' "$1"; else printf '\n\033[1;31mFAIL\033[0m  %s\n\n' "$1"; exit 1; fi
}
say() { printf '    %s\n' "$*"; }
has() { grep -q -- "$1" <<<"$2"; }                         # has PATTERN TEXT  (text is passed in, never piped)
number_is() { [ "$1" = "$2" ]; }
page() { curl -s -m 4 "$APP_URL/"; }

fresh() { # a brand-new demo namespace: 3 web pods, 1 notes pod, 1 volume, the ingress
  log "Creating a fresh demo namespace (the cluster itself keeps running)"
  reset_demo || { fail "could not reset the demo namespace. Run: ./scripts/kubectl.sh get ns; ./scripts/kubectl.sh -n demo get pods"; exit 1; }
}

# --- a background "visitor" that requests the page 10 times a second and records every status code ---
LOAD_DIR=""
load_start() {
  LOAD_DIR="$(mktemp -d)"
  ( while [ ! -f "$LOAD_DIR/stop" ]; do
      curl -s -o /dev/null -m 2 -w '%{http_code}\n' "$APP_URL/whoami.txt" >> "$LOAD_DIR/codes" 2>/dev/null || echo 000 >> "$LOAD_DIR/codes"
      sleep 0.1
    done ) &
  LOAD_PID=$!
}
load_stop() { # sets LOAD_TOTAL and LOAD_FAILED
  touch "$LOAD_DIR/stop"; wait "$LOAD_PID" 2>/dev/null
  LOAD_TOTAL="$(count_lines "$(cat "$LOAD_DIR/codes" 2>/dev/null)")"
  LOAD_FAILED="$(count_lines "$(grep -v '^200$' "$LOAD_DIR/codes" 2>/dev/null)")"
  rm -rf "$LOAD_DIR"
}
almost_no_failures() { [ "$LOAD_TOTAL" -ge 20 ] && [ $((LOAD_FAILED * 100)) -le "$LOAD_TOTAL" ]; }   # at most 1% failed

scenario_deploy() {
  log "SCENARIO deploy: from nothing to a running, load-balanced app with one command"
  local t0 t1 pods
  kc delete ns demo --wait=true --timeout=180s >/dev/null 2>&1
  assert "no demo namespace yet"                           ns_absent
  say "kubectl apply -f k8s/"
  t0="$(date +%s)"
  apply_all | sed 's/^/      /'
  wait_app 180; t1="$(date +%s)"
  say "ready in $((t1 - t0)) seconds"
  assert "3 web pods are Running and Ready"                number_is "$(ready_pods web)" 3
  assert "1 notes pod is Running and Ready"                number_is "$(ready_pods notes)" 1
  pods="$(replicas_seen 40)"
  say "the ingress answered with: $(echo $pods)"
  assert "requests were spread over all 3 pods"            number_is "$(count_lines "$pods")" 3
  assert "the page says which pod served it"               has "Served by Kubernetes pod" "$(page)"
  assert "the notes volume is Bound"                       number_is "$(kd get pvc notes-data -o jsonpath='{.status.phase}')" Bound
  finish deploy
}

scenario_selfheal() {
  log "SCENARIO selfheal: kill pods and containers; Kubernetes puts things back while traffic keeps flowing"
  fresh
  local victim restarts i
  load_start
  victim="$(pod_names web | head -n 1)"
  say "Deleting pod $victim"
  kd delete pod "$victim" --wait=false >/dev/null
  assert "a replacement pod appears (3 ready again)"       wait_ready_pods web 3 90
  assert "the deleted pod is gone"                         bash -c '! grep -qx "$0" <<<"$1"' "$victim" "$(pod_names web)"
  victim="$(pod_names web | head -n 1)"
  say "Crashing nginx inside $victim (nginx -s stop)"
  kd exec "$victim" -c nginx -- nginx -s stop >/dev/null 2>&1
  restarts=0
  for ((i = 0; i < 30; i++)); do
    restarts="$(kd get pod "$victim" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)"
    [ "${restarts:-0}" -ge 1 ] && break
    sleep 2
  done
  assert "the container was restarted by the kubelet"      test "${restarts:-0}" -ge 1
  assert "all 3 pods are Ready again"                      wait_ready_pods web 3 90
  load_stop
  say "during all this the visitor made $LOAD_TOTAL requests; $LOAD_FAILED failed"
  assert "the app stayed up (at most 1% of requests failed)" almost_no_failures
  finish selfheal
}

scenario_scale() {
  log "SCENARIO scale: change the replica count and the Service follows"
  fresh
  say "kubectl scale deploy/web --replicas=5"
  kd scale deploy/web --replicas=5 >/dev/null
  assert "5 pods become Ready"                             wait_ready_pods web 5 90
  assert "traffic reaches all 5 pods"                      number_is "$(count_lines "$(replicas_seen 60)")" 5
  say "kubectl scale deploy/web --replicas=3"
  kd scale deploy/web --replicas=3 >/dev/null
  assert "back to 3 pods"                                  wait_ready_pods web 3 90
  assert "traffic reaches exactly 3 pods"                  number_is "$(count_lines "$(replicas_seen 40)")" 3
  finish scale
}

scenario_rolling() {
  log "SCENARIO rolling: ship version 2 while visitors keep browsing, then roll back"
  fresh
  assert "the page starts on version 1"                    has "Version 1" "$(page)"
  load_start
  say "kubectl patch: change the pod template's version label to 2"
  kd patch deploy web -p '{"spec":{"template":{"metadata":{"labels":{"version":"2"}}}}}' >/dev/null
  assert "the rollout completes"                           kd rollout status deploy/web --timeout=150s
  assert "3 pods are Ready and no old ones remain"         wait_ready_pods web 3 60
  assert "the page now shows version 2"                    has "Version 2" "$(page)"
  say "kubectl rollout undo"
  kd rollout undo deploy/web >/dev/null
  assert "the rollback completes"                          kd rollout status deploy/web --timeout=150s
  assert "no old pods remain after the rollback"           wait_ready_pods web 3 60
  load_stop
  say "during both rollouts the visitor made $LOAD_TOTAL requests; $LOAD_FAILED failed"
  assert "no downtime (at most 1% of requests failed)"     almost_no_failures
  assert "the page is back on version 1"                   has "Version 1" "$(page)"
  finish rolling
}

scenario_config() {
  log "SCENARIO config: change a ConfigMap; pods pick it up with a controlled restart"
  fresh
  local msg="Changed through a ConfigMap"
  assert "the page shows the original message"             has "Running on Kubernetes" "$(page)"
  say "kubectl patch configmap web-config (the pods are NOT restarted by this)"
  kd patch configmap web-config -p "{\"data\":{\"APP_MESSAGE\":\"$msg\"}}" >/dev/null
  sleep 2
  assert "running pods still show the old message"         has "Running on Kubernetes" "$(page)"
  say "kubectl rollout restart deploy/web"
  kd rollout restart deploy/web >/dev/null
  assert "the rollout completes"                           kd rollout status deploy/web --timeout=150s
  assert "3 pods are Ready"                                wait_ready_pods web 3 60
  assert "the page shows the new message"                  has "$msg" "$(page)"
  finish config
}

scenario_persistence() {
  log "SCENARIO persistence: a pod dies, its data does not (PersistentVolumeClaim)"
  fresh
  local before after old new
  before="$(curl -s -m 4 "$APP_URL/notes/starts.log")"
  say "starts.log now: $(echo $before)"
  assert "the log has exactly 1 line (one start)"          number_is "$(count_lines "$before")" 1
  old="$(pod_names notes)"
  say "Deleting pod $old"
  kd delete pod "$old" --wait=true >/dev/null
  assert "a new notes pod becomes Ready"                   wait_ready_pods notes 1 90
  new="$(pod_names notes)"
  assert "it is a different pod"                           test "$old" != "$new"
  after="$(curl -s -m 4 "$APP_URL/notes/starts.log")"
  say "starts.log now: $(echo $after)"
  assert "the log now has 2 lines (history survived)"      number_is "$(count_lines "$after")" 2
  assert "the first line is unchanged"                     number_is "$(head -n 1 <<<"$after")" "$(head -n 1 <<<"$before")"
  assert "the same volume claim is still Bound"            number_is "$(kd get pvc notes-data -o jsonpath='{.status.phase}')" Bound
  finish persistence
}

scenario_rbac() {
  log "SCENARIO rbac: a service account can do only what its Role allows"
  fresh
  local sa="--as=system:serviceaccount:demo:viewer"
  say "kubectl auth can-i ... $sa"
  assert "viewer CAN list pods in demo"                    number_is "$(kc auth can-i list pods -n demo $sa 2>/dev/null)" yes
  assert "viewer CAN watch pods in demo"                   number_is "$(kc auth can-i watch pods -n demo $sa 2>/dev/null)" yes
  assert "viewer CANNOT delete pods"                       number_is "$(kc auth can-i delete pods -n demo $sa 2>/dev/null)" no
  assert "viewer CANNOT read secrets"                      number_is "$(kc auth can-i get secrets -n demo $sa 2>/dev/null)" no
  assert "viewer CANNOT list pods in kube-system"          number_is "$(kc auth can-i list pods -n kube-system $sa 2>/dev/null)" no
  assert "viewer CANNOT create deployments"                number_is "$(kc auth can-i create deployments -n demo $sa 2>/dev/null)" no
  assert "the admin (you) can do everything"               number_is "$(kc auth can-i '*' '*' 2>/dev/null)" yes
  finish rbac
}

case "${1:-all}" in
  deploy)       scenario_deploy ;;
  selfheal)     scenario_selfheal ;;
  scale)        scenario_scale ;;
  rolling)      scenario_rolling ;;
  config)       scenario_config ;;
  persistence)  scenario_persistence ;;
  rbac)         scenario_rbac ;;
  all)          scenario_deploy; scenario_selfheal; scenario_scale; scenario_rolling
                scenario_config; scenario_persistence; scenario_rbac
                echo "All scenarios passed." ;;
  *)            die "usage: $0 [deploy|selfheal|scale|rolling|config|persistence|rbac|all]" ;;
esac
