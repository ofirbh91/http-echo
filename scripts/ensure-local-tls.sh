#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
umask 077
tls_dir="$state_dir/tls"
mkdir -p "$tls_dir"
# Local certificate, explicitly trusted only by the verification commands.
# Reuse it while valid to avoid changing trust on every setup run.
if [[ ! -s "$tls_dir/tls.key" || ! -s "$tls_dir/tls.crt" ]] || \
   ! openssl x509 -in "$tls_dir/tls.crt" -checkend 604800 -noout >/dev/null 2>&1; then
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 90 \
    -keyout "$tls_dir/tls.key" -out "$tls_dir/tls.crt" \
    -subj "/CN=$host" -addext "subjectAltName=DNS:$host" \
    -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
    -addext 'extendedKeyUsage=serverAuth' 2>/dev/null
fi
openssl x509 -in "$tls_dir/tls.crt" -checkhost "$host" -noout
# Server-side apply avoids copying the private key into a last-applied annotation.
kube -n "$namespace" create secret tls http-echo-tls \
  --cert="$tls_dir/tls.crt" --key="$tls_dir/tls.key" --dry-run=client -o yaml |
  kube apply --server-side --field-manager=http-echo-local-tls -f -
