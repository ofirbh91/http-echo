#!/usr/bin/env bash
# Sourced by the local scripts, never changes kubectl's current context.
set -euo pipefail
chart_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
profile="${MINIKUBE_PROFILE:-http-echo-secure}"
if [[ ! "$profile" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  printf 'MINIKUBE_PROFILE must contain lowercase letters, digits, and hyphens.\n' >&2
  exit 1
fi
state_dir="$chart_dir/.local/$profile"
namespace=http-echo
host=http-echo.k8s-server.local
ingress_namespace=nginx-ingress
ingress_service=nginx-ingress-controller
ingress_image=nginx/nginx-ingress@sha256:2c3ae7869c8c935870f8760ee5db894c504410a7785312fd4a21cbb729b1db2d
mkdir -p "$state_dir"
# SPDY treats any inherited DEBUG value as enabling very verbose stream logs.
kube() { env -u DEBUG kubectl --context="$profile" "$@"; }
helm_rollback_flag() {
  case "$(helm version --short)" in
    v4.*) printf '%s' --rollback-on-failure ;;
    v3.*) printf '%s' --atomic ;;
    *) printf 'Helm 3 or 4 is required.\n' >&2; return 1 ;;
  esac
}
