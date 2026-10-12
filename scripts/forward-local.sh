#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
exec env -u DEBUG kubectl --context="$profile" -n "$ingress_namespace" port-forward \
  "service/$ingress_service" --address=127.0.0.1 \
  "${HTTP_PORT:-8080}:80" "${HTTPS_PORT:-8443}:443"
