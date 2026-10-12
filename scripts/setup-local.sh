#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != --check ) ]]; then
  printf 'Usage: bash scripts/setup-local.sh [--check]\n' >&2
  exit 2
fi
if [[ "$EUID" == 0 ]]; then
  printf 'Run setup as your normal user. Only the forwarding service installation uses sudo.\n' >&2
  exit 1
fi
for tool in docker minikube kubectl helm curl openssl python3 sha256sum; do
  command -v "$tool" >/dev/null || { printf 'Required command is missing: %s\n' "$tool" >&2; exit 1; }
done
python3 -c 'import sys; sys.exit("Python 3.12+ is required") if sys.version_info < (3, 12) else None'
helm_rollback_flag >/dev/null
case "${INSTALL_FORWARDER:-1}" in
  1)
    for tool in systemctl sudo; do
      command -v "$tool" >/dev/null || { printf 'Missing %s; use INSTALL_FORWARDER=0 for foreground access.\n' "$tool" >&2; exit 1; }
    done
    [[ -d /run/systemd/system ]] || { printf 'Systemd is not running; use INSTALL_FORWARDER=0 for foreground access.\n' >&2; exit 1; }
    ;;
  0) ;;
  *) printf 'INSTALL_FORWARDER must be 0 or 1.\n' >&2; exit 2 ;;
esac
docker info >/dev/null || { printf 'Docker is unavailable. Start Docker and check Linux/WSL access.\n' >&2; exit 1; }
if [[ "${1:-}" == --check ]]; then
  printf 'Prerequisites passed. Run: INSTALL_FORWARDER=%s bash scripts/setup-local.sh\n' "${INSTALL_FORWARDER:-1}"
  exit 0
fi

# A dedicated profile avoids silently replacing the network plugin of an existing cluster.
if ! minikube -p "$profile" status >/dev/null 2>&1; then
  minikube -p "$profile" start --driver=docker --cpus=2 --memory=3900 \
    --cni=calico --kubernetes-version="${KUBERNETES_VERSION:-v1.35.9}" --keep-context
fi
kube wait --for=condition=Ready nodes --all --timeout=300s
if ! kube -n kube-system get daemonset calico-node >/dev/null 2>&1; then
  printf 'This profile has no Calico policy enforcement. Use a new profile with --cni=calico.\n' >&2
  exit 1
fi
kube -n kube-system rollout status daemonset/calico-node --timeout=300s
if kube -n ingress-nginx get deployment ingress-nginx-controller >/dev/null 2>&1; then
  printf 'This profile still contains the retired ingress-nginx controller. Use a separate clean profile.\n' >&2
  exit 1
fi

bash "$chart_dir/scripts/build-image.sh"
minikube -p "$profile" image load "$(cat "$state_dir/image-ref")"

for ns in "$namespace" "$ingress_namespace"; do
  kube create namespace "$ns" --dry-run=client -o yaml | kube apply -f -
  kube label namespace "$ns" --overwrite \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=v1.35
done
bash "$chart_dir/scripts/ensure-local-tls.sh"

minikube -p "$profile" addons enable metrics-server
kube -n kube-system rollout status deployment/metrics-server --timeout=180s
kube wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=180s

bash "$chart_dir/scripts/install-ingress.sh"
helm upgrade --install http-echo "$chart_dir" --kube-context "$profile" \
  --namespace "$namespace" -f "$state_dir/image-values.yaml" \
  "$(helm_rollback_flag)" --wait --timeout 5m
helm test http-echo --kube-context "$profile" --namespace "$namespace" --logs --timeout 90s
bash "$chart_dir/scripts/test-network-policy.sh"
bash "$chart_dir/scripts/verify-https.sh"

# Optional on machines without systemd; the foreground forwarder remains available.
if [[ "${INSTALL_FORWARDER:-1}" == 1 ]]; then
  bash "$chart_dir/scripts/install-forwarding-service.sh"
fi
printf '\nLocal environment and application verified. Context: %s\n' "$profile"
printf 'Application: https://%s/\n' "$host"
printf 'Local certificate: %s/tls/tls.crt\n' "$state_dir"
printf 'For foreground access: bash scripts/forward-local.sh (ports 8080/8443).\n'
