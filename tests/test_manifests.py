"""Tests the Kubernetes manifests without a cluster: YAML structure, cross-references (Service selectors,
Ingress backends, ConfigMap keys), good practice (probes, resource limits, least-privilege RBAC), the pod's
page-rendering script (really executed with sh), and the nginx configs (checked with a real `nginx -t`).
If the optional `kubernetes-validate` package is installed, every manifest is also checked against the
official Kubernetes 1.30 schemas.

Needs PyYAML (python3-yaml); skipped without it.
"""
import glob
import importlib.util
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
HAVE_YAML = importlib.util.find_spec("yaml") is not None


def load_all():
    import yaml
    docs = []
    for path in sorted(glob.glob(os.path.join(ROOT, "k8s", "*.yaml"))):
        with open(path) as fh:
            for doc in yaml.safe_load_all(fh):
                if doc:
                    docs.append((os.path.basename(path), doc))
    return docs


def find(docs, kind, name):
    for _, d in docs:
        if d["kind"] == kind and d["metadata"]["name"] == name:
            return d
    raise KeyError(f"{kind}/{name}")


def pod_containers(deployment):
    spec = deployment["spec"]["template"]["spec"]
    return spec.get("initContainers", []) + spec["containers"]


@unittest.skipUnless(HAVE_YAML, "PyYAML not installed (python3-yaml)")
class ManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.docs = load_all()
        with open(os.path.join(ROOT, ".env.example")) as fh:
            cls.env = dict(re.findall(r"^(\w+)=(.*)$", fh.read(), re.M))

    def test_every_namespaced_object_is_in_the_demo_namespace(self):
        for fname, d in self.docs:
            if d["kind"] != "Namespace":
                self.assertEqual(d["metadata"].get("namespace"), "demo", f"{fname}: {d['kind']}/{d['metadata']['name']}")

    def test_files_apply_in_order_namespace_first(self):
        self.assertEqual(self.docs[0][1]["kind"], "Namespace")

    def test_all_images_are_the_one_pinned_nginx_image(self):
        images = {c["image"] for _, d in self.docs if d["kind"] == "Deployment" for c in pod_containers(d)}
        self.assertEqual(images, {self.env["NGINX_IMAGE"]})

    def test_every_container_has_requests_and_a_memory_limit(self):
        for _, d in self.docs:
            if d["kind"] == "Deployment":
                for c in pod_containers(d):
                    self.assertIn("requests", c["resources"], c["name"])
                    self.assertIn("memory", c["resources"]["limits"], c["name"])

    def test_web_has_probes_and_a_zero_downtime_strategy(self):
        web = find(self.docs, "Deployment", "web")
        self.assertEqual(web["spec"]["replicas"], 3)
        ru = web["spec"]["strategy"]["rollingUpdate"]
        self.assertEqual(ru["maxUnavailable"], 0)
        nginx = web["spec"]["template"]["spec"]["containers"][0]
        self.assertIn("readinessProbe", nginx)
        self.assertIn("livenessProbe", nginx)
        self.assertIn("preStop", nginx["lifecycle"])
        self.assertEqual(web["spec"]["template"]["metadata"]["labels"]["version"], "1")

    def test_notes_uses_recreate_with_a_claimed_volume(self):
        notes = find(self.docs, "Deployment", "notes")
        self.assertEqual(notes["spec"]["strategy"]["type"], "Recreate")
        vols = {v["name"]: v for v in notes["spec"]["template"]["spec"]["volumes"]}
        self.assertEqual(vols["data"]["persistentVolumeClaim"]["claimName"], "notes-data")
        find(self.docs, "PersistentVolumeClaim", "notes-data")

    def test_service_selectors_match_pod_labels(self):
        for app in ("web", "notes"):
            svc, dep = find(self.docs, "Service", app), find(self.docs, "Deployment", app)
            labels = dep["spec"]["template"]["metadata"]["labels"]
            for k, v in svc["spec"]["selector"].items():
                self.assertEqual(labels.get(k), v, app)
            for k, v in dep["spec"]["selector"]["matchLabels"].items():
                self.assertEqual(labels.get(k), v, app)

    def test_ingress_backends_point_at_real_services_and_ports(self):
        ing = find(self.docs, "Ingress", "demo")
        paths = ing["spec"]["rules"][0]["http"]["paths"]
        self.assertEqual({p["path"] for p in paths}, {"/", "/notes"})
        for p in paths:
            svc = find(self.docs, "Service", p["backend"]["service"]["name"])
            self.assertIn(p["backend"]["service"]["port"]["name"], [x["name"] for x in svc["spec"]["ports"]])

    def test_configmap_keys_used_by_pods_exist(self):
        cm = find(self.docs, "ConfigMap", "web-config")["data"]
        web = find(self.docs, "Deployment", "web")
        for v in web["spec"]["template"]["spec"]["volumes"]:
            for item in v.get("configMap", {}).get("items", []):
                self.assertIn(item["key"], cm)
        render = web["spec"]["template"]["spec"]["initContainers"][0]
        for e in render["env"]:
            ref = e.get("valueFrom", {}).get("configMapKeyRef")
            if ref:
                self.assertIn(ref["key"], cm)

    def test_rbac_is_least_privilege(self):
        role = find(self.docs, "Role", "pod-reader")
        for rule in role["rules"]:
            self.assertNotIn("*", rule["verbs"])
            self.assertNotIn("*", rule["resources"])
            self.assertTrue(set(rule["verbs"]) <= {"get", "list", "watch"})
        binding = find(self.docs, "RoleBinding", "viewer-reads-pods")
        self.assertEqual(binding["subjects"][0]["name"], "viewer")
        self.assertEqual(binding["roleRef"]["name"], "pod-reader")

    @unittest.skipUnless(importlib.util.find_spec("kubernetes_validate"), "kubernetes-validate not installed")
    def test_manifests_pass_the_official_kubernetes_schemas(self):
        import kubernetes_validate
        for fname, d in self.docs:
            kubernetes_validate.validate(d, "1.30", strict=True)

    def test_render_script_writes_the_page_for_the_pod(self):
        cm = find(self.docs, "ConfigMap", "web-config")["data"]
        tmp = tempfile.mkdtemp(prefix="render-")
        try:
            script = os.path.join(tmp, "render.sh")
            html = os.path.join(tmp, "html")
            os.makedirs(html)
            with open(script, "w") as fh:
                fh.write(cm["render.sh"].replace("/html/", html + "/"))
            env = dict(os.environ, POD_NAME="web-7d9f-abcde", POD_NAMESPACE="demo", POD_IP="10.42.0.7",
                       NODE_NAME="k8s-box", APP_VERSION="2", APP_MESSAGE="Hello & welcome")
            res = subprocess.run(["sh", script], env=env, capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, res.stderr)
            with open(os.path.join(html, "index.html")) as fh:
                page = fh.read()
            for text in ("Served by Kubernetes pod", "web-7d9f-abcde", "Version 2", "Hello & welcome", "10.42.0.7", "k8s-box"):
                self.assertIn(text, page)
            self.assertNotIn("${", page)
            with open(os.path.join(html, "whoami.txt")) as fh:
                self.assertEqual(fh.read(), "web-7d9f-abcde\n")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    @unittest.skipUnless(shutil.which("nginx"), "nginx not installed")
    def test_nginx_configs_are_valid(self):
        for cm_name in ("web-config", "notes-config"):
            conf = find(self.docs, "ConfigMap", cm_name)["data"]["default.conf"]
            tmp = tempfile.mkdtemp(prefix="nginx-")
            try:
                os.makedirs(os.path.join(tmp, "logs"))
                with open(os.path.join(tmp, "default.conf"), "w") as fh:
                    fh.write(conf)
                with open(os.path.join(tmp, "nginx.conf"), "w") as fh:
                    fh.write(f"pid {tmp}/nginx.pid;\nerror_log {tmp}/logs/error.log;\nevents {{}}\n"
                             f"http {{\n  access_log off;\n  include {tmp}/default.conf;\n}}\n")
                res = subprocess.run(["nginx", "-t", "-p", tmp, "-c", os.path.join(tmp, "nginx.conf")],
                                     capture_output=True, text=True)
                self.assertEqual(res.returncode, 0, cm_name + res.stderr)
            finally:
                shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
