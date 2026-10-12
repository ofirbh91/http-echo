"""Offline checks for security boundaries and production configuration.

Run: python3 -m unittest discover -s tests -p test_chart.py -v (requires PyYAML).
"""
import pathlib
import subprocess
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]


def render(*args):
    result = subprocess.run(
        ["helm", "template", "http-echo", str(ROOT), "--namespace", "http-echo", *args],
        text=True, capture_output=True, check=True,
    )
    return [doc for doc in yaml.safe_load_all(result.stdout) if doc]


class ChartSecurityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.docs = render()

    def test_application_and_test_pods_are_restricted(self):
        pods = [doc["spec"]["template"]["spec"] if doc["kind"] == "Deployment" else doc["spec"]
                for doc in self.docs if doc["kind"] in ("Deployment", "Pod")]
        self.assertEqual(len(pods), 2)
        for pod in pods:
            self.assertIs(pod["automountServiceAccountToken"], False)
            self.assertTrue(pod["securityContext"]["runAsNonRoot"])
            self.assertNotEqual(pod["securityContext"]["runAsUser"], 0)
            self.assertEqual(pod["securityContext"]["seccompProfile"]["type"], "RuntimeDefault")
            for container in pod["containers"]:
                self.assertFalse(container["securityContext"]["allowPrivilegeEscalation"])
                self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
                self.assertEqual(container["securityContext"]["capabilities"]["drop"], ["ALL"])
                self.assertIn("memory", container["resources"]["limits"])

    def test_service_routes_to_the_actual_nonprivileged_port(self):
        deployment = next(d for d in self.docs if d["kind"] == "Deployment")
        container = deployment["spec"]["template"]["spec"]["containers"][0]
        service = next(d for d in self.docs if d["kind"] == "Service")
        port = container["ports"][0]
        env = {e["name"]: e["value"] for e in container["env"]}
        self.assertGreater(port["containerPort"], 1024)
        self.assertEqual(str(port["containerPort"]), env["PORT"])
        self.assertEqual(port["name"], service["spec"]["ports"][0]["targetPort"])

    def test_network_policy_requires_both_ingress_namespace_and_labels(self):
        policy = next(d for d in self.docs if d["kind"] == "NetworkPolicy" and d["metadata"]["name"] == "http-echo")
        sources = policy["spec"]["ingress"][0]["from"]
        self.assertEqual(len(sources), 2)
        self.assertIn("namespaceSelector", sources[0])
        self.assertIn("podSelector", sources[0])
        self.assertEqual(sources[1]["podSelector"]["matchLabels"]["app.kubernetes.io/component"], "test")
        self.assertEqual(policy["spec"]["egress"], [])

    def test_production_rejects_a_mutable_image(self):
        result = subprocess.run(
            ["helm", "template", "http-echo", str(ROOT), "-f", str(ROOT / "values-production.yaml")],
            text=True, capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Production requires image.digest", result.stderr)

    def test_production_uses_digest_and_spreads_replicas(self):
        digest = "sha256:" + "a" * 64
        docs = render("-f", str(ROOT / "values-production.yaml"), "--set", "image.repository=registry.example/echo", "--set", f"image.digest={digest}")
        pod = next(d for d in docs if d["kind"] == "Deployment")["spec"]["template"]["spec"]
        self.assertEqual(pod["containers"][0]["image"], "registry.example/echo@" + digest)
        self.assertEqual(pod["topologySpreadConstraints"][0]["whenUnsatisfiable"], "DoNotSchedule")
        self.assertEqual(pod["topologySpreadConstraints"][0]["minDomains"], 2)
        self.assertGreaterEqual(next(d for d in docs if d["kind"] == "HorizontalPodAutoscaler")["spec"]["minReplicas"], 2)
        self.assertEqual(next(d for d in docs if d["kind"] == "PodDisruptionBudget")["spec"]["minAvailable"], 1)

    def test_static_replicas_when_autoscaling_disabled(self):
        docs = render("--set", "autoscaling.enabled=false", "--set", "replicaCount=2")
        self.assertFalse(any(d["kind"] == "HorizontalPodAutoscaler" for d in docs))
        self.assertEqual(next(d for d in docs if d["kind"] == "Deployment")["spec"]["replicas"], 2)


if __name__ == "__main__":
    unittest.main()
