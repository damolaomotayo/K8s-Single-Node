"""Tests the shell helpers in scripts/lib.sh with a stub `docker` command (no Docker or cluster needed):
how kubectl is invoked, how pod/deployment output is parsed, the waiting helpers and .env generation.
"""
import os
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

STUB_DOCKER = r"""#!/usr/bin/env bash
# Stub docker: logs every call; "exec ... kubectl" prints whatever STUB_KC_OUT holds.
echo "$*" >> "$STUB_LOG"
case "$1" in
  info) exit 0 ;;
  exec) [ -n "${STUB_KC_FAIL:-}" ] && exit 1
        printf '%b' "${STUB_KC_OUT:-}"; exit 0 ;;
esac
exit 0
"""

PODS = ("web-aaa   1/1   Running       0   5m\n"
        "web-bbb   1/1   Running       1   5m\n"
        "web-ccc   0/1   Running       0   5s\n"
        "web-ddd   1/1   Terminating   0   9m\n")


class ScriptHelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="k8s-scripts-")
        shutil.copytree(os.path.join(ROOT, "scripts"), os.path.join(self.tmp, "scripts"))
        shutil.copy(os.path.join(ROOT, ".env.example"), self.tmp)
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        path = os.path.join(self.bin, "docker")
        with open(path, "w") as fh:
            fh.write(STUB_DOCKER)
        os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
        self.log = os.path.join(self.tmp, "docker.log")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def sh(self, snippet, **extra_env):
        env = dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"], STUB_LOG=self.log, **extra_env)
        return subprocess.run(["bash", "-c", f'. "{self.tmp}/scripts/lib.sh"; {snippet}'], env=env,
                              capture_output=True, text=True, timeout=60)

    def logged(self):
        with open(self.log) as fh:
            return fh.read()

    def test_env_file_gets_a_random_token_that_never_changes(self):
        self.sh("true")
        with open(os.path.join(self.tmp, ".env")) as fh:
            first = fh.read()
        self.assertRegex(first, r"K3S_TOKEN=[0-9a-f]{32}")
        self.assertIn("K3S_IMAGE=rancher/k3s:", first)
        self.sh("true")
        with open(os.path.join(self.tmp, ".env")) as fh:
            self.assertEqual(first, fh.read())

    def test_kubectl_runs_inside_the_k3s_container(self):
        self.sh("kc get nodes; kd get pods -o wide")
        lines = self.logged().splitlines()
        self.assertIn("exec -i k8s-box-server kubectl get nodes", lines)
        self.assertIn("exec -i k8s-box-server kubectl -n demo get pods -o wide", lines)

    def test_ready_pods_counts_only_running_and_fully_ready(self):
        res = self.sh("ready_pods web", STUB_KC_OUT=PODS)
        self.assertEqual(res.stdout.strip(), "2")                 # not the 0/1 pod, not the Terminating one

    def test_wait_ready_pods_needs_exact_count_with_no_leftovers(self):
        only_good = "web-aaa 1/1 Running 0 5m\\nweb-bbb 1/1 Running 0 5m\\nweb-ccc 1/1 Running 0 5m\\n"
        ok = self.sh("sleep() { :; }; wait_ready_pods web 3 4; echo rc=$?", STUB_KC_OUT=only_good)
        self.assertIn("rc=0", ok.stdout)
        leftover = self.sh("sleep() { :; }; wait_ready_pods web 3 4; echo rc=$?", STUB_KC_OUT=only_good + "web-old 1/1 Terminating 0 9m\\n")
        self.assertIn("rc=1", leftover.stdout)

    def test_deploy_ready_compares_available_with_wanted(self):
        self.assertIn("rc=0", self.sh("deploy_ready demo web; echo rc=$?", STUB_KC_OUT="3/3").stdout)
        self.assertIn("rc=1", self.sh("deploy_ready demo web; echo rc=$?", STUB_KC_OUT="2/3").stdout)
        self.assertIn("rc=1", self.sh("deploy_ready demo web; echo rc=$?", STUB_KC_OUT="/3").stdout)

    def test_node_ready_wants_exactly_one_ready_node(self):
        self.assertIn("rc=0", self.sh("node_ready; echo rc=$?", STUB_KC_OUT="k8s Ready control-plane 1m v1.30\\n").stdout)
        self.assertIn("rc=1", self.sh("node_ready; echo rc=$?", STUB_KC_OUT="k8s NotReady control-plane 1m v1.30\\n").stdout)

    def test_api_ready_needs_the_word_ok(self):
        self.assertIn("rc=0", self.sh("api_ready; echo rc=$?", STUB_KC_OUT="ok").stdout)
        self.assertIn("rc=1", self.sh("api_ready; echo rc=$?", STUB_KC_FAIL="1").stdout)

    def test_pod_names_strip_the_prefix(self):
        res = self.sh("pod_names web", STUB_KC_OUT="pod/web-aaa\\npod/web-bbb\\n")
        self.assertEqual(res.stdout.split(), ["web-aaa", "web-bbb"])

    def test_count_lines(self):
        res = self.sh("count_lines ''; count_lines $'a\\nb\\nc'")
        self.assertEqual(res.stdout.split(), ["0", "3"])

    def test_wait_until_retries_then_gives_up(self):
        res = self.sh("sleep() { :; }; n=0; f() { n=$((n+1)); [ $n -ge 3 ]; }; wait_until 10 f; echo rc=$? n=$n; "
                      "wait_until 4 false; echo rc=$?")
        self.assertIn("rc=0 n=3", res.stdout)
        self.assertIn("rc=1", res.stdout.splitlines()[-1])


if __name__ == "__main__":
    unittest.main()
