"""Enforce the vulnerability gate without removing accepted findings from reports."""
import json
import sys
from pathlib import Path


def evaluate(report, image_ref, policy=None):
    if report.get("ArtifactName") != image_ref or not report.get("Results"):
        raise ValueError("Scan must contain results for the requested image")
    allowed = set()
    if policy is not None:
        if policy["image_ref"] != image_ref or "@sha256:" not in image_ref:
            raise ValueError("Exceptions apply only to the exact pinned image digest")
        allowed = {(v["target"], v["cve"], v["package"], v["version"])
                   for v in policy["allowed_high_findings"]}
    accepted, blocked = [], []
    for result in report["Results"]:
        for finding in result.get("Vulnerabilities", []):
            severity = finding["Severity"]
            if severity not in ("HIGH", "CRITICAL"):
                continue
            key = (result["Target"], finding["VulnerabilityID"],
                   finding["PkgName"], finding["InstalledVersion"])
            # CRITICAL findings can never use the HIGH exception list.
            destination = accepted if severity == "HIGH" and key in allowed else blocked
            destination.append({"target": result["Target"], **finding})
    return accepted, blocked


def main():
    report_path, image_ref, *policy_paths = sys.argv[1:]
    report = json.loads(Path(report_path).read_text())
    policy = json.loads(Path(policy_paths[0]).read_text()) if policy_paths else None
    accepted, blocked = evaluate(report, image_ref, policy)
    for label, findings in (("ACCEPTED EXCEPTION", accepted), ("BLOCKED", blocked)):
        for finding in findings:
            print(f"{label}: {finding['Severity']} {finding['VulnerabilityID']} "
                  f"{finding['PkgName']} {finding['InstalledVersion']} ({finding['target']})")
    print(f"Vulnerability gate: {len(blocked)} blocking findings; "
          f"{len(accepted)} documented HIGH exceptions. Raw report: {report_path}")
    return 1 if blocked else 0


if __name__ == "__main__":
    sys.exit(main())
