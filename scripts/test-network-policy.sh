#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
probe="http-echo-denied-$(date +%s)-$$"
service_ip="$(kube -n "$namespace" get service http-echo -o jsonpath='{.spec.clusterIP}')"
image_ref="$(cat "$state_dir/image-ref")"
trap 'kube -n "$namespace" delete pod "$probe" --ignore-not-found --wait=false >/dev/null' EXIT
python3 - "$probe" "$service_ip" "$image_ref" <<'PY' | kube -n "$namespace" create -f -
import json, sys
name, ip, image = sys.argv[1:]
code = """
const net = require('net');
const socket = net.connect({host: process.env.TARGET_IP, port: 5678});
socket.on('connect', () => { console.error('FAIL: unauthorized Pod connected'); process.exit(1); });
socket.on('error', e => { console.error('FAIL: inconclusive network error', e.message); process.exit(1); });
setTimeout(() => { socket.destroy(); console.log('PASS: unauthorized traffic blocked'); process.exit(0); }, 5000);
"""
print(json.dumps({'apiVersion':'v1','kind':'Pod','metadata':{'name':name},'spec':{
 'restartPolicy':'Never','activeDeadlineSeconds':45,'automountServiceAccountToken':False,
 'securityContext':{'runAsNonRoot':True,'runAsUser':1000,'runAsGroup':1000,'seccompProfile':{'type':'RuntimeDefault'}},
 'containers':[{'name':'probe','image':image,'imagePullPolicy':'Never',
  'command':['node','-e',code],'env':[{'name':'TARGET_IP','value':ip}],
  'resources':{'requests':{'cpu':'10m','memory':'32Mi'},'limits':{'cpu':'100m','memory':'128Mi'}},
  'securityContext':{'allowPrivilegeEscalation':False,'readOnlyRootFilesystem':True,'capabilities':{'drop':['ALL']}}}]
}}))
PY
if ! kube -n "$namespace" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$probe" --timeout=60s; then
  kube -n "$namespace" logs "$probe" || true
  exit 1
fi
kube -n "$namespace" logs "$probe"

# DNS worked in the authorized Helm test; the application itself needs no egress.
dns_ip="$(kube -n kube-system get service kube-dns -o jsonpath='{.spec.clusterIP}')"
kube -n "$namespace" exec deployment/http-echo -- node -e '
const net = require("net");
const socket = net.connect({host: process.argv[1], port: 53});
socket.on("connect", () => { console.error("FAIL: application egress allowed"); process.exit(1); });
socket.on("error", e => { console.error("FAIL: inconclusive egress error", e.message); process.exit(1); });
setTimeout(() => { socket.destroy(); console.log("PASS: application egress blocked"); process.exit(0); }, 5000);
' "$dns_ip"
