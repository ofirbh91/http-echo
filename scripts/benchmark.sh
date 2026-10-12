#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
port="${TEST_HTTPS_PORT:-18443}"
kube -n "$ingress_namespace" port-forward "service/$ingress_service" --address=127.0.0.1 "$port:443" \
  > "$state_dir/benchmark-forward.log" 2>&1 &
forward_pid=$!
trap 'kill "$forward_pid" 2>/dev/null || true; wait "$forward_pid" 2>/dev/null || true' EXIT
ready=false
for attempt in {1..30}; do
  if ! kill -0 "$forward_pid" 2>/dev/null; then cat "$state_dir/benchmark-forward.log" >&2; exit 1; fi
  if curl --noproxy '*' -fsS --max-time 2 --cacert "$state_dir/tls/tls.crt" \
    --connect-to "$host:443:127.0.0.1:$port" "https://$host/" >/dev/null 2>&1; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == true ]] || { printf 'HTTPS endpoint is not ready.\n' >&2; exit 1; }
python3 "$chart_dir/scripts/benchmark.py" --context "$profile" --port "$port" \
  --ca "$state_dir/tls/tls.crt" --duration "${BENCHMARK_SECONDS:-30}" \
  --concurrency "${BENCHMARK_CONCURRENCY:-8}" --output "$state_dir/benchmark.json"
