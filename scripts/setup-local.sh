#!/usr/bin/env bash
set -euo pipefail

profile="${MINIKUBE_PROFILE:-minikube}"

for tool in docker minikube kubectl helm curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Required command is missing: %s\n' "$tool" >&2
    exit 1
  fi
done

docker info >/dev/null

# Reuse a healthy cluster; start it only when necessary.
if ! minikube -p "$profile" status >/dev/null 2>&1; then
  minikube -p "$profile" start \
    --driver=docker \
    --cpus=2 \
    --memory=3900 \
    --keep-context
fi

kubectl --context="$profile" wait --for=condition=Ready nodes --all --timeout=180s
minikube -p "$profile" addons enable ingress
kubectl --context="$profile" -n ingress-nginx rollout status \
  deployment/ingress-nginx-controller --timeout=180s
kubectl --context="$profile" get ingressclass nginx

# Reserve a namespace for the assignment without installing the broken chart.
kubectl --context="$profile" create namespace http-echo --dry-run=client -o yaml |
  kubectl --context="$profile" apply -f -

cluster_ip="$(minikube -p "$profile" ip)"
status="$(curl --noproxy '*' --silent --show-error --output /dev/null \
  --write-out '%{http_code}' --connect-timeout 5 --max-time 15 \
  --resolve "http-echo-env-check.invalid:80:$cluster_ip" \
  http://http-echo-env-check.invalid/)"

# An unmatched host must reach NGINX's default backend, which returns 404.
if [[ "$status" != 404 ]]; then
  printf 'Ingress check failed: expected HTTP 404, received %s\n' "$status" >&2
  exit 1
fi

printf '\nLocal environment is ready.\n'
printf 'Kubernetes context: %s\n' "$profile"
printf 'Application namespace: http-echo\n'
printf 'Ingress IP (from this Linux/WSL environment): %s\n' "$cluster_ip"
printf 'Ingress connectivity: HTTP %s (expected for an unmatched host)\n' "$status"
printf 'Next step: repair the Helm chart and deploy http-echo.\n'
