#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
docker build --file "$chart_dir/image/Dockerfile" --tag http-echo-local:hardened "$chart_dir"
image_id="$(docker image inspect http-echo-local:hardened --format '{{.Id}}')"
image_tag="${image_id#sha256:}"
image_ref="http-echo-local:$image_tag"
docker tag "$image_id" "$image_ref"
bash "$chart_dir/scripts/scan-image.sh" "$image_ref" application
# The local tag is the exact content ID; registry deployments must use @sha256.
printf 'image:\n  repository: http-echo-local\n  tag: "%s"\n  digest: ""\n  pullPolicy: Never\n' \
  "$image_tag" > "$state_dir/image-values.yaml"
printf '%s\n' "$image_ref" > "$state_dir/image-ref"

