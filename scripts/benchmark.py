#!/usr/bin/env python3
"""Small local HTTPS smoke benchmark, not a production capacity estimate."""
import argparse
import concurrent.futures
import http.client
import json
import pathlib
import socket
import ssl
import statistics
import subprocess
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--context', default='http-echo-secure')
parser.add_argument('--port', type=int, default=18443)
parser.add_argument('--duration', type=int, default=30)
parser.add_argument('--concurrency', type=int, default=8)
parser.add_argument('--ca', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
if not 1 <= args.duration <= 120 or not 1 <= args.concurrency <= 16:
    parser.error('duration must be 1..120 seconds; concurrency must be 1..16')
hostname = 'http-echo.k8s-server.local'
tls = ssl.create_default_context(cafile=args.ca)


class LocalConnection(http.client.HTTPSConnection):
    def connect(self):
        self.sock = tls.wrap_socket(socket.create_connection(('127.0.0.1', args.port), timeout=5), server_hostname=hostname)


samples = []
stop = threading.Event()


def sample_resources():
    while not stop.is_set():
        row = {'elapsed_seconds': round(time.monotonic() - started, 2)}
        for name, command in {
            'pods': ['top', 'pods', '--containers'],
            'hpa': ['get', 'hpa', '-o', 'json'],
        }.items():
            result = subprocess.run(['kubectl', '--context=' + args.context, '-n', 'http-echo', *command], text=True, capture_output=True, timeout=10)
            row[name] = result.stdout if result.returncode == 0 else result.stderr
        samples.append(row)
        stop.wait(5)


def worker():
    durations, failures = [], 0
    connection = LocalConnection(hostname, context=tls, timeout=5)
    while time.monotonic() < deadline:
        begin = time.monotonic()
        try:
            connection.request('GET', '/', headers={'Host': hostname})
            response = connection.getresponse()
            payload = json.loads(response.read())
            if response.status != 200 or payload['http']['method'] != 'GET':
                raise ValueError('Unexpected application response')
            durations.append((time.monotonic() - begin) * 1000)
        except (OSError, ValueError, KeyError, http.client.HTTPException):
            failures += 1
            connection.close()
            connection = LocalConnection(hostname, context=tls, timeout=5)
            time.sleep(0.05)
    connection.close()
    return durations, failures


started = time.monotonic()
deadline = started + args.duration
sampler = threading.Thread(target=sample_resources)
sampler.start()
with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as executor:
    results = list(executor.map(lambda _: worker(), range(args.concurrency)))
elapsed = time.monotonic() - started
stop.set()
sampler.join()
durations = sorted(value for result, _ in results for value in result)
errors = sum(count for _, count in results)
report = {
    'scope': 'Local HTTPS through kubectl port-forward; client and cluster share host resources. Not production sizing evidence.',
    'context': args.context,
    'duration_seconds': round(elapsed, 2),
    'concurrency': args.concurrency,
    'successful_requests': len(durations),
    'errors': errors,
    'requests_per_second': round(len(durations) / elapsed, 2),
    'latency_ms': {
        'median': round(statistics.median(durations), 2) if durations else None,
        'p95': round(durations[min(len(durations)-1, int(len(durations)*0.95))], 2) if durations else None,
    },
    'resource_samples': samples,
}
pathlib.Path(args.output).write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({key: value for key, value in report.items() if key != 'resource_samples'}, indent=2))
raise SystemExit(1 if errors or not durations else 0)
