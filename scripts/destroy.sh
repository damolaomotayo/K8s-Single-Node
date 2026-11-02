#!/usr/bin/env bash
# Removes everything this project created on the instance: the cluster container, its data volume
# (cluster state and cached images) and the k3s image.
# Usage: ./scripts/destroy.sh [--keep-env]
set -uo pipefail
. "$(dirname "$0")/lib.sh"

log "Stopping the cluster and deleting its volume"
$DC down -v --remove-orphans

# k3s starts containerd inside its own container, so everything it ran is gone with the container.
# Remove any leftover from an interrupted run, just in case.
leftover="$($DOCKER ps -aq --filter 'name=^k8s-box-')"
[ -z "$leftover" ] || $DOCKER rm -f $leftover >/dev/null

log "Removing the k3s image"
$DOCKER rmi -f "${K3S_IMAGE:-rancher/k3s:v1.30.5-k3s1}" >/dev/null 2>&1 || true
$DOCKER image prune -f >/dev/null 2>&1 || true

if [ "${1:-}" != "--keep-env" ]; then rm -f "$ROOT/.env"; fi

echo
echo "Cleanup done. (The nginx image stays cached; remove with: sudo docker image prune -af)"
echo "IMPORTANT: terminate the EC2 instance in the AWS console (EC2 > Instances >"
echo "Instance state > Terminate) so it stops costing money. Then delete the security group."
