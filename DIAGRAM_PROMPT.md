# Diagram prompt (copy everything below into an image-generation model)

Create a clean, professional cloud infrastructure diagram, 16:9 landscape, white background, flat vector style, large readable labels, thin dark-grey lines, soft pastel fills. Title at the top: "Kubernetes on One Node: a real cluster on one EC2 instance".

LAYOUT, left to right.

LEFT: a "Browser (your laptop)" box with two items: "http://<EC2-PUBLIC-IP>:8080/ (web app)" and "http://<EC2-PUBLIC-IP>:8080/notes/starts.log (notes)". Solid arrows labeled "HTTP 8080" go to the right. Below it a small "Terminal (SSH port 22)" box with a dashed arrow to the right.

MIDDLE: a thin firewall icon labeled "Security group: inbound SSH 22 and TCP 8080, both from my IP only; outbound all".

RIGHT: a large AWS-orange-bordered box labeled "AWS Region > Default VPC > EC2 instance m7i-flex.large (Ubuntu 24.04, 2 vCPU, 8 GiB)". Inside it, one big blue rounded box labeled "Docker Engine". Inside that, one large green box labeled "k3s container (one-node Kubernetes cluster)". Inside the green box:
1. Top: a small box "API server + controllers" and a box "kubectl (runs inside this container)".
2. Left: a box "Traefik Ingress (host port 8080 to container port 80)" with two routes: "/" and "/notes".
3. Middle: a namespace frame "namespace: demo". Inside it a box "Service: web" feeding a group "Deployment: web, 3 replicas (Pods)" drawn as three small pod icons labeled "Pod web-1", "Pod web-2", "Pod web-3", each with a tiny label "init container renders page; nginx". Below it a box "Service: notes" feeding one pod "Pod notes" attached to a cylinder "PersistentVolumeClaim 100Mi (local-path volume)". At the side: a "ConfigMap: web-config" box with a dotted arrow to the web pods, and a "ServiceAccount viewer + Role pod-reader (RBAC)" box.
4. Bottom: "CoreDNS" and "local-path provisioner" small boxes.

Numbered arrows, each with a short label:
1. Browser to Traefik Ingress: "port 8080".
2. Ingress "/" to Service web, then spread to the 3 pods: "load balanced".
3. Ingress "/notes" to Service notes to the notes pod to the volume: "log survives pod restarts".
4. Terminal to kubectl: "kubectl apply -f k8s/".
5. API server to the pods: "desired state: 3 replicas".
6. A red cross on one web pod with a green arrow creating a replacement: "self-healing".
7. Old and new pods side by side: "rolling update: version 1 to version 2, one pod at a time".
8. ConfigMap to pods: "config change plus rollout restart".

Add a small legend: blue = public entry point, green = Kubernetes control and workloads, red = failure that gets healed. Add a footer note: "The whole cluster is one Docker container on this one instance. No other AWS services are used."

Do not add any AWS services (no EKS, ALB, EBS, IAM). Use generic icons, with the Kubernetes wheel and a simple Docker whale as the only logos. Make sure all text is spelled exactly as written above.
