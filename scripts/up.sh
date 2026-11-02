#!/usr/bin/env bash
# Starts the Kubernetes cluster (k3s in one container) and deploys the demo app into it.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

log "Starting the cluster (first start downloads Kubernetes' own images, 1-3 minutes; later starts take ~20 seconds)"
$DC up -d

log "Waiting for the Kubernetes API"
wait_until 240 api_ready || die "The API did not become ready. Run: $DOCKER logs --tail 40 $SERVER"
ok "API is ready"
wait_until 240 node_ready || die "The node never became Ready. Run: $DOCKER logs --tail 40 $SERVER"
ok "the node is Ready"

log "Waiting for the cluster's built-in services (DNS, ingress, storage)"
wait_until 300 deploy_exists kube-system traefik || die "Traefik was not created. Run: ./scripts/kubectl.sh -n kube-system get pods"
wait_until 300 system_ready || die "System pods are not ready. Run: ./scripts/kubectl.sh -n kube-system get pods"
ok "coredns, traefik and local-path-provisioner are running"

log "Deploying the demo app: kubectl apply -f k8s/"
apply_all
wait_app 180 || die "The app did not become ready. Run: ./scripts/kubectl.sh -n demo get pods"
ok "web (3 pods) and notes are up"

IP="$(public_ip)"
cat <<EOF

Cluster is up. Open this in your browser (from the laptop allowed by the security group):
  App   : http://${IP}:8080/                  <- refresh: a different pod answers each time
  Notes : http://${IP}:8080/notes/starts.log  <- written to a persistent volume

Look inside:   ./scripts/kubectl.sh get nodes      ./scripts/kubectl.sh -n demo get pods -o wide
Next: ./scripts/smoke.sh   then   ./scripts/demo.sh all
EOF
