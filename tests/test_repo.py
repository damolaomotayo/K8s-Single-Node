"""Sanity tests for the repo itself (layout, scripts, config, docs). Stdlib only. Run from the repo root:
    python3 -m unittest discover -s tests -v
"""
import os
import re
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

REQUIRED_FILES = [
    "README.md", "STEPS.md", "DEMO.md", "DIAGRAM_PROMPT.md", ".gitignore", ".gitattributes", ".env.example",
    "docker-compose.yml",
    "k8s/00-namespace.yaml", "k8s/10-web.yaml", "k8s/20-notes.yaml", "k8s/30-ingress.yaml", "k8s/40-rbac.yaml",
    "scripts/lib.sh", "scripts/kubectl.sh", "scripts/setup.sh", "scripts/preflight.sh", "scripts/up.sh",
    "scripts/smoke.sh", "scripts/demo.sh", "scripts/destroy.sh",
    "tests/test_manifests.py", "tests/test_scripts.py",
]
SCRIPTS = [f for f in REQUIRED_FILES if f.endswith(".sh")]


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
        return fh.read()


class LayoutTests(unittest.TestCase):
    def test_required_files_exist(self):
        for rel in REQUIRED_FILES:
            self.assertTrue(os.path.isfile(os.path.join(ROOT, rel)), f"missing {rel}")

    def test_scripts_have_shebang(self):
        for rel in SCRIPTS:
            self.assertTrue(read(rel).startswith("#!/usr/bin/env bash"), rel)

    def test_no_crlf_line_endings(self):
        for rel in SCRIPTS + [f for f in REQUIRED_FILES if f.endswith((".yaml", ".yml"))]:
            with open(os.path.join(ROOT, rel), "rb") as fh:
                self.assertNotIn(b"\r\n", fh.read(), rel)

    def test_no_env_file_is_shipped(self):
        self.assertFalse(os.path.exists(os.path.join(ROOT, ".env")))
        self.assertIn(".env", read(".gitignore"))


class ConfigTests(unittest.TestCase):
    def test_only_the_ingress_port_is_published(self):
        ports = re.findall(r'-\s*"([^"]+)"', read("docker-compose.yml"))
        published = [p for p in ports if re.match(r"^(\d+\.\d+\.\d+\.\d+:)?\d+:\d+$", p)]
        self.assertEqual(published, ["8080:80"])

    def test_the_kubernetes_api_is_never_published(self):
        self.assertNotIn("6443", read("docker-compose.yml").replace("(6443)", "").replace("# ", "#"))

    def test_token_comes_from_env_not_from_the_file(self):
        self.assertIn("K3S_TOKEN: ${K3S_TOKEN:?", read("docker-compose.yml"))
        self.assertNotRegex(read(".env.example"), r"K3S_TOKEN=\w")

    def test_images_are_official_and_pinned(self):
        env = dict(re.findall(r"^(\w+)=(.*)$", read(".env.example"), re.M))
        self.assertRegex(env["K3S_IMAGE"], r"^rancher/k3s:v\d+\.\d+\.\d+-k3s\d+$")
        self.assertRegex(env["NGINX_IMAGE"], r"^nginx:\d+\.\d+")
        self.assertIn(env["K3S_IMAGE"], read("docker-compose.yml"))        # the compose default matches .env.example

    def test_k3s_data_is_a_named_volume_so_images_are_cached(self):
        compose = read("docker-compose.yml")
        self.assertIn("k3s-data:/var/lib/rancher/k3s", compose)
        self.assertIn("\nvolumes:\n  k3s-data:", compose)


class ScriptRuleTests(unittest.TestCase):
    def test_no_curl_f_against_docker_hub(self):
        for rel in SCRIPTS:
            for line in read(rel).splitlines():
                if "registry-1.docker.io" in line and "curl" in line:
                    self.assertNotRegex(line, r"curl\s+-\w*f", f"{rel}: {line}")

    def test_preflight_accepts_http_200_and_401_for_docker_hub(self):
        text = read("scripts/preflight.sh")
        self.assertIn('"$code" = "200"', text)
        self.assertIn('"$code" = "401"', text)

    def test_no_pipe_into_grep_q(self):                     # under pipefail this randomly fails
        for rel in SCRIPTS:
            for n, line in enumerate(read(rel).splitlines(), 1):
                if line.strip().startswith("#"):
                    continue
                self.assertNotRegex(line, r"\|\s*grep\s+-\w*q", f"{rel}:{n}: {line}")

    def test_demo_has_all_scenarios_and_smoke_has_a_count(self):
        demo = read("scripts/demo.sh")
        for name in ("deploy", "selfheal", "scale", "rolling", "config", "persistence", "rbac"):
            self.assertIn(f"scenario_{name}()", demo)
        smoke = read("scripts/smoke.sh")
        self.assertEqual(len(re.findall(r"^check ", smoke, re.M)), 15)
        self.assertIn("All %d checks passed.", smoke)

    def test_demo_does_not_exit_on_the_first_failed_check(self):
        self.assertNotRegex(read("scripts/demo.sh"), r"^set -\w*e")

    def test_rolling_patch_uses_a_label_that_exists_in_the_manifest(self):
        self.assertIn('"version":"2"', read("scripts/demo.sh"))
        self.assertIn('version: "1"', read("k8s/10-web.yaml"))


class DocsTests(unittest.TestCase):
    def test_steps_has_prerequisites_first_and_the_key_items(self):
        text = read("STEPS.md")
        self.assertLess(text.index("## Prerequisites"), text.index("## Step 0"))
        for needle in ("8080", "chmod +x scripts/*.sh", "chmod 400", "All 15 checks passed.",
                       "sudo apt update", "Terminate", "My IP", "t3.large" if False else "m7i-flex.large"):
            self.assertIn(needle, text)

    def test_demo_md_is_very_short(self):
        text = read("DEMO.md")
        self.assertLess(len(text.split()), 450)
        self.assertLess(len(text.splitlines()), 40)

    def test_diagram_prompt_mentions_the_main_parts(self):
        text = read("DIAGRAM_PROMPT.md")
        for needle in ("Kubernetes", "k3s", "Ingress", "Deployment", "8080", "PersistentVolume"):
            self.assertIn(needle, text)

    def test_every_script_is_documented_in_steps(self):
        steps = read("STEPS.md")
        for rel in ("setup.sh", "preflight.sh", "up.sh", "smoke.sh", "demo.sh", "destroy.sh", "kubectl.sh"):
            self.assertIn(rel, steps)


if __name__ == "__main__":
    unittest.main()
