#!/usr/bin/env bash
# Shared helpers. Sourced by the other scripts, not run directly.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# Use plain docker if the current user may talk to the daemon, otherwise sudo.
if docker info >/dev/null 2>&1; then DOCKER="docker"; else DOCKER="sudo docker"; fi
DC="$DOCKER compose"

SERVER="k8s-box-server"                              # the container that IS the Kubernetes node
APP_URL="${APP_URL:-http://127.0.0.1:8080}"          # the ingress, as seen from the instance itself

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

set_env() { # KEY VALUE: add the line to .env unless it is already there
  grep -q "^$1=" "$ROOT/.env" || echo "$1=$2" >> "$ROOT/.env"
}
ensure_env() { # create .env on first run and give the cluster a random join token
  [ -f "$ROOT/.env" ] || cp "$ROOT/.env.example" "$ROOT/.env"
  set_env K3S_TOKEN "$(openssl rand -hex 16)"
  set -a; . "$ROOT/.env"; set +a
}
ensure_env

# ---- kubectl runs INSIDE the k3s container (nothing to install on the instance) ----
kc() { $DOCKER exec -i "$SERVER" kubectl "$@"; }      # kc get nodes
kd() { kc -n demo "$@"; }                             # kd get pods     (same, in the demo namespace)

public_ip() { # EC2 metadata (IMDSv2), then a public what-is-my-ip fallback
  local tok ip=""
  tok="$(curl -fsS -m 2 -X PUT http://169.254.169.254/latest/api/token \
         -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  if [ -n "$tok" ]; then
    ip="$(curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $tok" \
          http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
  fi
  if [ -z "$ip" ]; then
    ip="$(curl -fsS -m 4 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  echo "${ip:-<EC2-PUBLIC-IP>}"
}

http_code() { curl -s -o /dev/null -m 4 -w '%{http_code}' "$1" 2>/dev/null || true; }   # 000 = no connection

wait_http() { # LABEL URL [SECONDS]  (any 2xx)
  local label="$1" url="$2" secs="${3:-60}" i
  for ((i = 0; i < secs; i++)); do
    if curl -fsS -o /dev/null --max-time 2 "$url" 2>/dev/null; then ok "$label is up"; return 0; fi
    sleep 1
  done
  fail "$label did not answer at $url within ${secs}s"
  return 1
}

# ---- waiting for the cluster ----
wait_until() { # SECONDS COMMAND...   (retries every 2 seconds)
  local secs="$1" i; shift
  for ((i = 0; i < secs; i += 2)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
api_ready()   { local out; out="$(kc get --raw /readyz 2>/dev/null)"; [ "$out" = "ok" ]; }
node_ready()  { local out; out="$(kc get nodes --no-headers 2>/dev/null)"; [ "$(awk '$2 == "Ready"' <<<"$out" | wc -l | tr -d ' ')" = "1" ]; }
deploy_exists() { kc -n "$1" get deploy "$2"; }                          # deploy_exists NAMESPACE NAME
deploy_ready() { # NAMESPACE NAME: all replicas available
  local out; out="$(kc -n "$1" get deploy "$2" -o jsonpath='{.status.availableReplicas}/{.spec.replicas}' 2>/dev/null)"
  [ -n "$out" ] && [ "${out%/*}" = "${out#*/}" ]
}
system_ready() { # coredns, traefik and the storage provisioner are Available
  deploy_ready kube-system coredns && deploy_ready kube-system traefik && deploy_ready kube-system local-path-provisioner
}

# ---- looking at the demo app ----
ready_pods() { # LABEL-VALUE: how many pods with app=<value> are Running, 1/1 ready and not terminating
  local out; out="$(kd get pods -l "app=$1" --no-headers 2>/dev/null)"
  awk '$2 == "1/1" && $3 == "Running"' <<<"$out" | wc -l | tr -d ' '
}
wait_ready_pods() { # LABEL-VALUE COUNT [SECONDS]: exactly COUNT ready pods, and no others left over
  local i total
  for ((i = 0; i < ${3:-60}; i += 2)); do
    total="$(kd get pods -l "app=$1" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    [ "$(ready_pods "$1")" = "$2" ] && [ "$total" = "$2" ] && return 0
    sleep 2
  done
  return 1
}
pod_names() { kd get pods -l "app=$1" -o name 2>/dev/null | sed 's|^pod/||'; }
replicas_seen() { # [REQUESTS]: the distinct pod names the ingress answered with, one per line
  local n="${1:-30}" i
  for ((i = 0; i < n; i++)); do curl -s -m 3 "$APP_URL/whoami.txt"; done | sort -u
}
count_lines() { if [ -z "$1" ]; then echo 0; else grep -c . <<<"$1"; fi; }   # count_lines TEXT

# ---- the demo namespace ----
apply_all() { kc apply -f /manifests/; }
ingress_up() { [ "$(http_code "$APP_URL/whoami.txt")" = "200" ]; }
wait_app() { # until web (3 pods) and notes are up and the ingress answers
  wait_until "${1:-150}" deploy_ready demo web && wait_until "${1:-150}" deploy_ready demo notes && wait_until 60 ingress_up
}
reset_demo() { # delete the namespace (everything in it, including the volume) and create it again
  if kc get ns demo >/dev/null 2>&1; then kc delete ns demo --wait=true --timeout=180s >/dev/null 2>&1 || return 1; fi
  apply_all >/dev/null && wait_app
}
