# Demo cheat sheet (1-minute read)

**What it does:** **Kubernetes** runs your containers for you: it keeps the right number alive, replaces dead ones, spreads traffic and ships new versions without downtime. Here a real cluster (**k3s**) runs on this one EC2 instance, with a web app (3 copies), a notes app with a saved disk, and a front door (**Ingress**) on port 8080.

**How it works:**
1. You describe the **desired state** in YAML files (`k8s/`): "3 copies of web, 1 notes with a 100 MB disk".
2. `kubectl apply -f k8s/` hands it to the cluster. Controllers keep reality equal to the description, forever.
3. A **Service** gives the 3 copies one name and shares traffic across them; the **Ingress** exposes it on `http://<EC2-PUBLIC-IP>:8080/`.
4. Every page says **which pod** served it. Refresh and the name changes.
5. **RBAC** limits what each account may do.

**Example 1: self-healing (`./scripts/demo.sh selfheal`)**
Keep `http://<PUBLIC-IP>:8080/` open. Delete a pod, then crash nginx inside another. The cluster starts a replacement and restarts the container by itself, while a background visitor keeps getting answers.

**Example 2: zero-downtime update (`./scripts/demo.sh rolling`)**
Version 1 becomes version 2 one pod at a time (a new pod must be Ready before an old one stops). Refresh: "Version 2". Then `rollout undo` goes back, again without downtime.

**Bonus:** `scale` (3 to 5 pods), `config` (ConfigMap change plus controlled restart), `persistence` (delete the notes pod, its log survives), `rbac` (a read-only account cannot delete).

**If asked "why not just Docker Compose?":** Compose starts containers. Kubernetes keeps them in the state you declared, heals them, rolls updates safely and works the same on 1 or 1,000 machines.
