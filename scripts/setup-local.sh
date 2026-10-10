#!/usr/bin/env bash
set -euo pipefail

profile="${MINIKUBE_PROFILE:-minikube}"
ingress_service="http-echo-ingress.service"
ingress_ip="127.0.0.1"

for tool in docker minikube kubectl helm curl systemctl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Required command is missing: %s\n' "$tool" >&2
    exit 1
  fi
done

docker info >/dev/null

# The WSL access path is managed by the systemd unit installed separately.
if ! service_state="$(systemctl show "$ingress_service" --property=LoadState --value)"; then
  printf 'Cannot query systemd. Run this script inside WSL with systemd enabled.\n' >&2
  exit 1
fi
if [[ "$service_state" != loaded ]]; then
  printf 'Install the ingress forwarding service first, from the repository root:\n' >&2
  printf '  sudo install -m 0644 ops/systemd/%s /etc/systemd/system/\n' "$ingress_service" >&2
  printf '  sudo systemctl daemon-reload\n' >&2
  printf '  sudo systemctl enable --now %s\n' "$ingress_service" >&2
  printf 'Check User, KUBECONFIG, and the kubectl path in the unit for this machine.\n' >&2
  exit 1
fi

# Avoid checking a localhost forward that points to a different cluster.
service_command="$(systemctl show "$ingress_service" --property=ExecStart --value)"
if [[ "$service_command" != *"--context=$profile "* ]]; then
  printf '%s must use --context=%s to match MINIKUBE_PROFILE.\n' "$ingress_service" "$profile" >&2
  printf 'Update the unit, then run sudo systemctl daemon-reload and restart it.\n' >&2
  exit 1
fi

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

# The CPU-based HPA needs the resource metrics API, including on a fresh cluster.
minikube -p "$profile" addons enable metrics-server
kubectl --context="$profile" -n kube-system rollout status \
  deployment/metrics-server --timeout=180s
kubectl --context="$profile" wait --for=condition=Available \
  apiservice/v1beta1.metrics.k8s.io --timeout=180s

# Ensure the application namespace exists; Helm deploys the application separately.
kubectl --context="$profile" create namespace http-echo --dry-run=client -o yaml |
  kubectl --context="$profile" apply -f -

# Keep forwarding managed in the background, without a separate terminal.
if ! systemctl is-active --quiet "$ingress_service"; then
  printf 'Starting %s (sudo may ask for your password).\n' "$ingress_service"
  if ! sudo systemctl start "$ingress_service"; then
    printf 'Could not start %s. Inspect it with systemctl status.\n' "$ingress_service" >&2
    exit 1
  fi
fi

# Allow a short startup window before the background forward starts listening.
if ! status="$(curl --noproxy '*' --silent --show-error --output /dev/null \
  --write-out '%{http_code}' --connect-timeout 5 --max-time 10 \
  --retry 5 --retry-connrefused --retry-delay 2 --retry-max-time 20 \
  --resolve "http-echo-env-check.invalid:80:$ingress_ip" \
  http://http-echo-env-check.invalid/)"; then
  printf 'Cannot reach the ingress through %s:80.\n' "$ingress_ip" >&2
  printf 'Inspect the forwarding service:\n' >&2
  printf '  systemctl status %s --no-pager\n' "$ingress_service" >&2
  printf '  sudo journalctl -u %s -n 40 --no-pager\n' "$ingress_service" >&2
  exit 1
fi

# An unmatched host must reach NGINX's default backend, which returns 404.
if [[ "$status" != 404 ]]; then
  printf 'Ingress check failed: expected HTTP 404, received %s\n' "$status" >&2
  exit 1
fi

printf '\nLocal environment is ready.\n'
printf 'Kubernetes context: %s\n' "$profile"
printf 'Application namespace: http-echo\n'
printf 'Metrics API: available for resource-based autoscaling\n'
printf 'Ingress access: %s:80 via %s\n' "$ingress_ip" "$ingress_service"
printf 'Ingress connectivity: HTTP %s (expected for an unmatched host)\n' "$status"
printf 'This verifies the infrastructure; test the application separately for HTTP 200 and JSON.\n'
