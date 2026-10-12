#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
image_ref="${1:?Usage: scan-image.sh IMAGE [REPORT_NAME] [EXCEPTION_POLICY]}"
report_name="${2:-application}"
exception_policy="${3:-}"
[[ "$report_name" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 1
scanner="${TRIVY_BIN:-trivy}"
if ! command -v "$scanner" >/dev/null 2>&1; then
  scanner="$chart_dir/.local/tools/trivy"
  if [[ ! -x "$scanner" ]]; then
    # Verify the pinned release checksum before executing the downloaded binary.
    case "$(uname -m)" in
      x86_64) arch=64bit ;;
      aarch64|arm64) arch=ARM64 ;;
      *) printf 'Install Trivy for your architecture.\n' >&2; exit 1 ;;
    esac
    version=0.75.0
    tools_dir="$chart_dir/.local/tools"
    mkdir -p "$tools_dir"
    archive="trivy_${version}_Linux-${arch}.tar.gz"
    base="https://github.com/aquasecurity/trivy/releases/download/v$version"
    curl -fsSL --max-time 180 "$base/$archive" -o "$tools_dir/$archive"
    curl -fsSL --max-time 60 "$base/trivy_${version}_checksums.txt" -o "$tools_dir/checksums.txt"
    python3 - "$tools_dir" "$archive" <<'PY'
import hashlib, pathlib, sys, tarfile
root, name = pathlib.Path(sys.argv[1]), sys.argv[2]
expected = next(line.split()[0] for line in (root / 'checksums.txt').read_text().splitlines() if line.split()[-1] == name)
assert hashlib.sha256((root / name).read_bytes()).hexdigest() == expected, 'Trivy checksum mismatch'
with tarfile.open(root / name) as archive:
    archive.extract('trivy', root, filter='data')
PY
  fi
fi
"$scanner" image --cache-dir "${TRIVY_CACHE_DIR:-$chart_dir/.local/trivy-cache}" \
  --scanners vuln --severity HIGH,CRITICAL --exit-code 0 \
  --ignorefile /dev/null --ignore-unfixed=false \
  --format json --output "$state_dir/$report_name-scan.json" "$image_ref"
python3 "$chart_dir/scripts/check-scan.py" \
  "$state_dir/$report_name-scan.json" "$image_ref" ${exception_policy:+"$exception_policy"}
