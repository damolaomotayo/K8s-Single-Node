# Kubernetes on One Node

A real Kubernetes cluster (**k3s**) running on a single EC2 instance, with a small app that shows what Kubernetes is for: self-healing, load balancing, zero-downtime updates, config changes, persistent storage and access control. Nothing but Docker is installed on the instance; k3s and `kubectl` live inside one container. No AWS services other than EC2.

```
Browser :8080 --> Traefik Ingress --> Service web   --> 3 x web pods (nginx, page shows its pod name)
                                  \-> Service notes --> 1 x notes pod --> PersistentVolumeClaim (100Mi)
```

## What is in it

| Part | What it shows |
|---|---|
| `docker-compose.yml` | Starts k3s (`rancher/k3s`, privileged) as one container. Only port 8080 (the ingress) is published; the Kubernetes API stays inside. |
| `k8s/10-web.yaml` | Deployment (3 pods, rolling updates with no downtime, health probes), Service, ConfigMap, init container that renders each pod's page |
| `k8s/20-notes.yaml` | Deployment with a PersistentVolumeClaim; `Recreate` strategy because the volume is single-writer |
| `k8s/30-ingress.yaml` | Ingress: `/` goes to web, `/notes` to notes |
| `k8s/40-rbac.yaml` | ServiceAccount `viewer` that can only read pods |
| `scripts/` | `setup`, `preflight`, `up`, `smoke`, `demo`, `kubectl`, `destroy` |
| `tests/` | Manifest tests (schemas, probes, selectors, RBAC, nginx config), script tests, repo tests |

## Quick start (on Ubuntu 24.04 with sudo)

```bash
chmod +x scripts/*.sh
./scripts/setup.sh        # installs Docker (once)
./scripts/preflight.sh    # pulls images, starts the cluster once, deploys the app, runs tests
./scripts/up.sh           # (re)starts the cluster and deploys the app
./scripts/smoke.sh        # 15 checks, ends with "All 15 checks passed."
./scripts/demo.sh all     # seven scenarios
./scripts/kubectl.sh get pods -A     # use kubectl any time
./scripts/destroy.sh      # remove everything (after the demo)
```

Open `http://<EC2-PUBLIC-IP>:8080/` (security group: TCP 8080 from your IP). See **STEPS.md** for the full walkthrough and **DEMO.md** for the one-page talk track.

## Notes

- Requirements: 2 vCPU, 4 GiB RAM or more, 8 GiB free disk. k3s idles at about 1 GiB.
- The first cluster start downloads Kubernetes' own images (1-3 minutes). Preflight does this early and caches them in the `k3s-data` volume, so the demo starts fast. Do not run `destroy.sh` before the demo.
- k3s needs a **privileged** container. That is fine on a throwaway instance; do not copy this pattern to production.
- Pin or change versions in `.env` (`K3S_IMAGE`, `NGINX_IMAGE`).
