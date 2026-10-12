#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
# Use the official Alpine image unchanged. The exception is scoped to this digest.
docker pull "$ingress_image"
bash "$chart_dir/scripts/scan-image.sh" "$ingress_image" ingress \
  "$chart_dir/ops/nginx-scan-exceptions.json"

chart_version=2.7.3
chart_sha=41a46244e6fef7177bc18f9153f407309c58ce713f6945f6b5d20bedf0752549
archive="$chart_dir/.local/nginx-ingress-$chart_version.tgz"
if [[ ! -f "$archive" ]]; then
  helm pull nginx-ingress --repo https://helm.nginx.com/stable \
    --version "$chart_version" --destination "$chart_dir/.local"
fi
printf '%s  %s\n' "$chart_sha" "$archive" | sha256sum --check --status
kube apply -f "$chart_dir/ops/nginx-rbac.yaml"
helm upgrade --install nginx-ingress "$archive" --kube-context "$profile" \
  --namespace "$ingress_namespace" --skip-crds -f "$chart_dir/ops/nginx-values.yaml" \
  "$(helm_rollback_flag)" --wait --timeout 5m
