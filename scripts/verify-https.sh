#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
http_port="${TEST_HTTP_PORT:-18080}"
https_port="${TEST_HTTPS_PORT:-18443}"
kube -n "$ingress_namespace" port-forward "service/$ingress_service" --address=127.0.0.1 \
  "$http_port:80" "$https_port:443" > "$state_dir/verify-forward.log" 2>&1 &
forward_pid=$!
trap 'kill "$forward_pid" 2>/dev/null || true; wait "$forward_pid" 2>/dev/null || true' EXIT
for attempt in {1..30}; do
  if ! kill -0 "$forward_pid" 2>/dev/null; then
    cat "$state_dir/verify-forward.log" >&2
    exit 1
  fi
  if curl --noproxy '*' -sS --max-time 2 --output /dev/null \
    "http://127.0.0.1:$http_port/" 2>/dev/null; then break; fi
  sleep 1
done
curl --noproxy '*' -sS --max-time 15 \
  --connect-to "$host:80:127.0.0.1:$http_port" \
  -D "$state_dir/redirect-headers.txt" -o /dev/null "http://$host/"
python3 - "$state_dir/redirect-headers.txt" "$host" <<'PY'
import pathlib, sys
headers = pathlib.Path(sys.argv[1]).read_text().splitlines()
assert int(headers[0].split()[1]) in (301, 302, 307, 308), 'HTTP must redirect to HTTPS'
location = next(line.split(':', 1)[1].strip() for line in headers if line.lower().startswith('location:'))
assert location in (f'https://{sys.argv[2]}/', f'https://{sys.argv[2]}:443/'), location
PY
# No -k: verify the certificate chain, expiration, and hostname.
curl --noproxy '*' --fail --silent --show-error --max-time 15 \
  --retry 10 --retry-delay 2 --retry-all-errors --retry-max-time 45 \
  --cacert "$state_dir/tls/tls.crt" \
  --connect-to "$host:443:127.0.0.1:$https_port" \
  -H 'Authorization: Bearer synthetic-test-token' -H 'Cookie: synthetic-test-cookie=1' \
  -D "$state_dir/https-headers.txt" -o "$state_dir/https-response.json" "https://$host/"
python3 - "$state_dir" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
headers = (root / 'https-headers.txt').read_text().lower()
assert ' 200 ' in headers.splitlines()[0], headers.splitlines()[0]
assert 'content-type: application/json' in headers
payload = json.loads((root / 'https-response.json').read_text())
assert payload['http']['method'] == 'GET' and payload['http']['originalUrl'] == '/'
assert not payload.get('environment'), 'Environment leaked'
request = payload['request']
assert not request.get('cookies'), 'Cookies leaked'
assert 'authorization' not in request.get('headers', {}), 'Authorization header leaked'
assert 'cookie' not in request.get('headers', {}), 'Cookie header leaked'
assert request['headers']['x-forwarded-proto'] == 'https', 'Original HTTPS scheme lost'
print('PASS: HTTP redirect, verified TLS, HTTP 200, JSON, and no credential/environment echo')
PY
