# STEPS: Kubernetes on One Node

## Prerequisites (set these up BEFORE step 1)

| Need | Details |
|---|---|
| **AWS account** | Any account that can launch EC2. No IAM role, no other AWS service. Use one region for everything below. |
| **Instance type** | `m7i-flex.large` (2 vCPU, 8 GiB). This project needs about 2 GiB. |
| **OS image (AMI)** | Ubuntu Server 24.04 LTS (64-bit x86). 22.04 also works. |
| **Disk** | 20 GiB gp3. |
| **Key pair** | An RSA `.pem` key pair created in EC2 (step 0a). |
| **Security group** | Created in step 0b. **Inbound: exactly two rules: (1) SSH, TCP port 22; (2) Custom TCP, port 8080 (the app). Both with source My IP.** **Outbound: leave the default (All traffic, 0.0.0.0/0)**, because the instance must reach Docker Hub (images, including the ones k3s pulls) and Docker's apt repo. The Kubernetes API (6443) is never opened. |
| **Code on the instance** | Option A: private GitHub repo plus a fine-grained token (Contents: Read) used as the password for `git clone`. Option B: copy the zip with `scp` (step 2). |
| **Accounts / tokens** | None. The cluster token is generated on the instance (git-ignored `.env`). |
| **On your laptop** | A terminal with `ssh`/`scp` and a web browser. **No SSH tunnel is needed:** open `http://<PUBLIC-IP>:8080/` directly. |

**Time:** about 10 minutes of setup (the first cluster start downloads images), 6 minutes for the full demo. **Cost:** about $0.10/hour at your quoted rate, plus pennies for the disk. Do step 12 when finished.

---

## Step 0: Create the key pair, security group and instance (AWS console)

**0a. Key pair.** EC2 > Network & Security > Key pairs > **Create key pair**. Name `k8s-lab-key`, type **RSA**, format **.pem**. The file downloads once; keep it safe. On your laptop, lock down its permissions:

```bash
# Linux / macOS
chmod 400 ~/Downloads/k8s-lab-key.pem
```
```powershell
# Windows PowerShell (OpenSSH)
icacls "$HOME\Downloads\k8s-lab-key.pem" /inheritance:r /grant:r "$($env:USERNAME):(R)"
```

**0b. Security group.** EC2 > Network & Security > Security Groups > **Create security group**.
- Name: `k8s-lab-sg`, Description: `SSH and app from my IP`, VPC: the default VPC.
- **Inbound rules > Add rule** (do it twice):
  1. Type `SSH`, Protocol `TCP`, Port range `22`, Source `My IP`
  2. Type `Custom TCP`, Protocol `TCP`, Port range `8080`, Source `My IP`
- **Outbound rules:** leave the default rule (Type `All traffic`, Destination `0.0.0.0/0`).
- Click **Create security group**.

> Showing the demo to someone on a different network? Their browser is blocked by "My IP". Either share your screen, or add their public IP followed by `/32` as the source of the 8080 rule. Do not use `0.0.0.0/0`.

**0c. Launch the instance.** EC2 > Instances > **Launch instances**.
- Name: `k8s-lab-box`
- Application and OS Image: **Ubuntu**, choose **Ubuntu Server 24.04 LTS**, architecture **64-bit (x86)**
- Instance type: `m7i-flex.large`
- Key pair: `k8s-lab-key`
- Network settings > **Edit**: Auto-assign public IP **Enable**; Firewall: **Select existing security group** > `k8s-lab-sg`
- Configure storage: **20 GiB**, `gp3`
- Advanced details > IAM instance profile: leave as **No IAM role**
- Click **Launch instance**, wait until Instance state is `Running` and Status check is `2/2 passed`, then copy the **Public IPv4 address**. This is your `<PUBLIC-IP>` below.

> If your network changes later, SSH and the pages will time out because "My IP" no longer matches. Edit **both** inbound rules of `k8s-lab-sg` and set Source to My IP again. Stopping and starting the instance also gives it a new public IP.

## Step 1: Connect to the instance (from your laptop)

```bash
ssh -i ~/Downloads/k8s-lab-key.pem ubuntu@<PUBLIC-IP>
```
Type `yes` at the fingerprint prompt. Every command from here to step 11 runs **on the instance**.

## Step 2: Update packages and get the code

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git unzip
```

**Option A (private GitHub repo):**
```bash
git clone https://github.com/<you>/k8s-single-node.git
cd k8s-single-node
```
When asked, username = your GitHub username, password = the fine-grained token.

**Option B (no GitHub), run from your laptop in the folder holding the zip, then continue on the instance:**
```bash
# on your laptop
scp -i ~/Downloads/k8s-lab-key.pem k8s-single-node.zip ubuntu@<PUBLIC-IP>:~
# on the instance
unzip k8s-single-node.zip
cd k8s-single-node
```

## Step 3: Make the scripts executable (do not skip)

Files that were zipped, uploaded to GitHub or copied between systems often lose their "executable" flag. Without this you get `Permission denied`.

```bash
chmod +x scripts/*.sh
ls -l scripts/        # every .sh line should start with -rwxr-xr-x
```

## Step 4: Install Docker

```bash
./scripts/setup.sh
```
It runs `apt update`/`upgrade`, installs `ca-certificates curl git gnupg openssl python3 python3-yaml unzip`, installs Docker Engine and Compose v2 from Docker's official repo (falling back to Ubuntu's `docker.io` package if that repo is unreachable), starts Docker and prints the versions. Takes 3-5 minutes. It ends with `Setup complete.` Kubernetes itself is **not** installed on the instance: k3s and `kubectl` run inside one container.

## Step 5: Unit tests

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```
Ends with `OK` (a few seconds). They check the manifests (selectors, probes, RBAC, ConfigMap keys, the page-rendering script) and the scripts, without needing the cluster. Tests that need the optional `kubernetes-validate` or `nginx` packages show as `skipped`; that is normal.

## Step 6: Preflight (run this well before the demo)

```bash
./scripts/preflight.sh
```
Creates `.env` with a random cluster token; checks Docker, disk (8 GB), memory (3.5 GB) and port 8080; checks that Docker Hub is reachable; pulls the k3s and nginx images; **starts the cluster once** (Kubernetes downloads its own images now, 1-3 minutes), deploys the app once, and runs the tests. Every line must say `ok`, and the last line is `Preflight passed. The cluster is running with the app deployed.` First run takes 4-8 minutes.

## Step 7: Start the cluster and deploy the app

```bash
./scripts/up.sh
```
Starts the k3s container (a no-op if preflight left it running), waits for the API, the node and the system pods (DNS, ingress, storage), then runs `kubectl apply -f k8s/` and waits until the app answers. It prints:

```
App   : http://<PUBLIC-IP>:8080/
Notes : http://<PUBLIC-IP>:8080/notes/starts.log
```

## Step 8: Health check

```bash
./scripts/smoke.sh
```
Every line says `ok` and it ends with **`All 15 checks passed.`**

## Step 9: Open the app in your browser (on your laptop)

- `http://<PUBLIC-IP>:8080/`: a page saying `Served by Kubernetes pod web-...`. **Refresh several times: the pod name changes** (three different pods).
- `http://<PUBLIC-IP>:8080/notes/starts.log`: the notes pod's start log, stored on a persistent volume.

## Step 10: Run the demo (on the instance)

```bash
./scripts/demo.sh all           # all seven scenarios, about 6 minutes
```
Or one at a time (each starts from a freshly created `demo` namespace; the cluster keeps running):
```bash
./scripts/demo.sh deploy        # one apply: 3 web pods + notes + volume + ingress; traffic reaches all 3 pods
./scripts/demo.sh selfheal      # delete a pod, crash nginx; Kubernetes repairs it while visitors keep being served
./scripts/demo.sh scale         # 3 -> 5 -> 3 pods; the Service follows
./scripts/demo.sh rolling       # version 1 -> 2 with no downtime, then rollout undo
./scripts/demo.sh config        # ConfigMap change shows only after a controlled rollout restart
./scripts/demo.sh persistence   # delete the notes pod; its log (on the volume) survives
./scripts/demo.sh rbac          # a read-only service account can list pods but not delete them
```
Each scenario ends with a green `PASS`. Keep `http://<PUBLIC-IP>:8080/` open and refresh while they run.

## Step 11: Useful commands (a manual walkthrough you can do live)

```bash
./scripts/kubectl.sh get nodes                                  # the one-node cluster
./scripts/kubectl.sh -n demo get pods -o wide                   # pods, their IPs and the node
./scripts/kubectl.sh -n demo get deploy,svc,ingress,pvc         # everything the app is made of
./scripts/kubectl.sh -n demo delete pod <web-pod-name>          # kill one; watch a new one appear
./scripts/kubectl.sh -n demo get pods -w                        # watch live (Ctrl+C to stop)
./scripts/kubectl.sh -n demo scale deploy/web --replicas=5      # more copies
./scripts/kubectl.sh -n demo rollout history deploy/web         # update history
./scripts/kubectl.sh -n demo describe pod <web-pod-name>        # events: why a pod is not ready
./scripts/kubectl.sh -n demo logs deploy/notes                  # app logs
./scripts/kubectl.sh auth can-i delete pods -n demo --as=system:serviceaccount:demo:viewer   # no
```

## Step 12: Clean up, then terminate the instance

```bash
./scripts/destroy.sh
```
Then in the AWS console: EC2 > Instances > select `k8s-lab-box` > **Instance state > Terminate instance**. Optionally delete the `k8s-lab-sg` security group and `k8s-lab-key` key pair too.

---

## What you should see

| Step | Result |
|---|---|
| 5 | Tests end with `OK` |
| 6 | All `ok`, then `Preflight passed.` |
| 7 | Two URLs containing your public IP |
| 8 | `All 15 checks passed.` |
| 9 | A page naming the pod that served it; the name changes on refresh |
| 10 | Seven `PASS` lines, then `All scenarios passed.` |

## Risky dependencies and fallbacks

| Dependency | Risk | Fallback |
|---|---|---|
| Docker Hub (`rancher/k3s`, `nginx`) | Rate limit or a withdrawn tag | `sudo docker login` with a free account, or change `K3S_IMAGE` / `NGINX_IMAGE` in `.env` and re-run preflight |
| Images that k3s itself pulls (DNS, Traefik, storage) on first start | Slow or blocked network; first start takes 1-3 minutes | Preflight does this early and keeps the images in the `k3s-data` volume. **Run preflight early** |
| Privileged container (k3s needs it) | Blocked on a hardened host | Preflight checks it. Not an issue on a plain Ubuntu EC2 instance |
| k3s tag `v1.30.5-k3s1` | Tag not found | Set `K3S_IMAGE` in `.env` to another `rancher/k3s` tag from Docker Hub |
| Rolling-update check | One failed request in a hundred is tolerated | If it fails often, give the instance more time (do not run other heavy things) |
| Do not run `destroy.sh` before the demo | It deletes the cluster, its cached images and the k3s image | Re-run preflight afterwards |
| MinIO, LocalStack | **Not used** | none needed |

## If something goes wrong

| Symptom | Fix |
|---|---|
| SSH: `Connection timed out` | Your IP changed. Edit security group `k8s-lab-sg`, inbound rule SSH port 22, Source My IP. Also confirm the instance is Running and has a public IP. |
| Browser: page never loads at `http://<PUBLIC-IP>:8080/` | (1) Use `http://` not `https://`, and include `:8080`. (2) The inbound rule for 8080 must exist with Source My IP. (3) Check the IP is the instance's current public IP. (4) On the instance: `curl -i http://localhost:8080/healthz` should return `200`. If it works, the problem is the security group. If not, see the next rows. |
| `curl` on the instance returns `404 page not found` | Traefik is up but the app is not deployed: `./scripts/kubectl.sh apply -f /manifests/` |
| `curl` returns `Connection refused` | The cluster is not running: `sudo docker ps`, then `./scripts/up.sh` |
| Testing the public IP from the instance itself hangs | Expected: the security group only allows your laptop's IP. Use `localhost` on the instance. |
| SSH: `Permission denied (publickey)` | Use user `ubuntu` (not `ec2-user`), the right `.pem`, and `chmod 400` on it. |
| SSH: `UNPROTECTED PRIVATE KEY FILE` | `chmod 400 k8s-lab-key.pem` |
| `./scripts/x.sh: Permission denied` | `chmod +x scripts/*.sh` (step 3). Or run with `bash scripts/x.sh`. |
| `bad interpreter: /usr/bin/env bash^M` | Windows line endings. Run `sed -i 's/\r$//' scripts/*.sh` |
| `permission denied` on the Docker socket in your own commands | The scripts use `sudo` for you. For manual commands use `sudo docker ...`, or log out and back in once. |
| Preflight: `Docker Hub reachable` or a pull fails | Check the outbound rule is All traffic; `sudo docker login` with a free account; try again in a minute. |
| Preflight: `Privileged containers are allowed` fails | The Docker daemon forbids privileged containers. Use a plain Ubuntu EC2 instance with Docker from `setup.sh`. |
| Preflight: `Port 8080 is free` fails | `sudo ss -ltnp \| grep ':8080 '`, stop what uses it, or `./scripts/destroy.sh` if it is an old run of this project. |
| Preflight: `k3s starts` fails | `sudo docker logs --tail 60 k8s-box-server`. Usual causes: not enough memory, or a bad `K3S_IMAGE` tag. |
| Preflight: `coredns, traefik and storage are running` fails | The cluster is still pulling images. Wait a minute and run `./scripts/kubectl.sh -n kube-system get pods`; `ImagePullBackOff` means Docker Hub trouble. Then re-run preflight. |
| Pods stuck in `Pending` or `ContainerCreating` | `./scripts/kubectl.sh -n demo describe pod <name>` and read the Events at the bottom. |
| Pods in `ImagePullBackOff` | The cluster cannot pull `nginx`. Check outbound access; re-run preflight, which warms the cache. |
| `demo.sh`: `The cluster is not running` | `./scripts/up.sh` |
| `demo.sh`: `could not reset the demo namespace` | `./scripts/kubectl.sh get ns` (a stuck `Terminating` namespace clears itself within a minute), then run again. |
| `demo.sh rolling` reports failed requests | The instance was busy. Run it again on its own. |
| Disk full | `sudo docker system prune -af` (this removes cached images; preflight pulls them again) |
