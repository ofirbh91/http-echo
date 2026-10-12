#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
if [[ "$EUID" == 0 ]]; then
  printf 'Run this script as your normal user; only the installation step uses sudo.\n' >&2
  exit 1
fi
command -v systemctl >/dev/null || { printf 'Use scripts/forward-local.sh on systems without systemd.\n' >&2; exit 1; }
kubectl_path="$(command -v kubectl)"
kubeconfig_path="${KUBECONFIG:-$HOME/.kube/config}"
[[ -f "$kubeconfig_path" ]] || { printf 'A single KUBECONFIG file is required.\n' >&2; exit 1; }
python3 - "$chart_dir/ops/systemd/http-echo-ingress.service" "$state_dir/http-echo-ingress.service" \
  "$(id -un)" "$kubeconfig_path" "$kubectl_path" "$profile" <<'PY'
import pathlib, sys
source, target, user, config, kubectl, profile = sys.argv[1:]
def escape(value):
    if '\n' in value or '\r' in value: raise ValueError('Newlines are not allowed in unit values')
    return value.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%')
text = pathlib.Path(source).read_text()
for key, value in {'USER': user, 'KUBECONFIG': escape(config), 'KUBECTL': '"'+escape(kubectl)+'"', 'PROFILE': profile}.items():
    text = text.replace('@'+key+'@', value)
pathlib.Path(target).write_text(text)
PY
if [[ "${1:-}" == --render-only ]]; then
  printf '%s\n' "$state_dir/http-echo-ingress.service"
  exit 0
fi
printf 'Installing the forwarding service for user %s and context %s.\n' "$(id -un)" "$profile"
sudo install -m 0644 "$state_dir/http-echo-ingress.service" /etc/systemd/system/http-echo-ingress.service
sudo systemctl daemon-reload
sudo systemctl enable http-echo-ingress.service
sudo systemctl restart http-echo-ingress.service
systemctl is-active --quiet http-echo-ingress.service
