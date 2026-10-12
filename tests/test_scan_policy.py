"""Check that accepting the known controller findings cannot bypass other findings."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("check_scan", ROOT / "scripts/check-scan.py")
check_scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_scan)


class ScanPolicyTests(unittest.TestCase):
    def setUp(self):
        self.policy = json.loads((ROOT / "ops/nginx-scan-exceptions.json").read_text())
        self.image = self.policy["image_ref"]
        self.report = {"ArtifactName": self.image, "Results": [{
            "Target": "nginx-ingress", "Vulnerabilities": [
                {"Severity": "HIGH", "VulnerabilityID": v["cve"],
                 "PkgName": v["package"], "InstalledVersion": v["version"]}
                for v in self.policy["allowed_high_findings"]]}]}

    def test_known_findings_are_accepted_and_preserved(self):
        before = copy.deepcopy(self.report)
        accepted, blocked = check_scan.evaluate(self.report, self.image, self.policy)
        self.assertEqual((len(accepted), len(blocked)), (4, 0))
        self.assertEqual(self.report, before)

    def test_no_policy_blocks_all_high_findings(self):
        accepted, blocked = check_scan.evaluate(self.report, self.image)
        self.assertEqual((len(accepted), len(blocked)), (0, 4))

    def test_unlisted_cve_version_target_and_critical_are_blocked(self):
        for change in ({"VulnerabilityID": "CVE-NEW"}, {"InstalledVersion": "v0.1.0"},
                       {"PkgName": "unreviewed-package"}, {"Severity": "CRITICAL"}):
            with self.subTest(change=change):
                report = copy.deepcopy(self.report)
                report["Results"][0]["Vulnerabilities"][0].update(change)
                self.assertEqual(len(check_scan.evaluate(report, self.image, self.policy)[1]), 1)
        self.report["Results"][0]["Target"] = "another-binary"
        self.assertEqual(len(check_scan.evaluate(self.report, self.image, self.policy)[1]), 4)

    def test_different_image_cannot_reuse_exceptions(self):
        image = "nginx/nginx-ingress@sha256:" + "a" * 64
        self.report["ArtifactName"] = image
        with self.assertRaises(ValueError):
            check_scan.evaluate(self.report, image, self.policy)

    def test_missing_or_mismatched_scan_fails_closed(self):
        for report in ({}, {"ArtifactName": self.image, "Results": []},
                       {**self.report, "ArtifactName": "another-image"}):
            with self.subTest(report=report), self.assertRaises(ValueError):
                check_scan.evaluate(report, self.image, self.policy)


if __name__ == "__main__":
    unittest.main()
