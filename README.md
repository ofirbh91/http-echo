# HTTP Echo on Kubernetes

A local Kubernetes application that echoes HTTP requests as JSON, exposed over
HTTPS through the official F5 NGINX Ingress Controller. The setup uses Minikube,
Calico network policies, Helm and vulnerability scanning.

```text
Client HTTPS → localhost port-forward → NGINX → Service:5678 → application:8080
```

The original task is preserved in [docs/assignment.md](docs/assignment.md).
Use the instructions below to run the implemented solution.

## Contents

- [Prerequisites](#prerequisites)
- [First-time setup](#first-time-setup)
- [Verify and access the application](#verify-and-access-the-application)
- [Run without systemd](#run-without-systemd)
- [Stop, restart or recreate the environment](#stop-restart-or-recreate-the-environment)
- [Troubleshooting](#troubleshooting)
- [Configuration and project files](#configuration-and-project-files)
- [Additional checks and deployment scope](#additional-checks-and-deployment-scope)

## Prerequisites

The validated platform is **Linux or WSL2 on x86-64 (`linux/amd64`)**. On Windows,
run the project commands in a WSL terminal. The controller image digest was
validated for this architecture; ARM support requires a separate image review.

| Requirement | Check |
|---|---|
| Docker running and accessible to your normal user | `docker info` succeeds without sudo |
| Minikube | `minikube version` |
| kubectl compatible with the cluster version | `kubectl version --client` |
| Helm 3 or 4 | `helm version --short` |
| Python 3.12 or newer | `python3 --version` |
| Bash, curl, OpenSSL and `sha256sum` | Commands available in `PATH` |
| Internet access | Required for sources, images, Helm charts and the vulnerability database |
| systemd and sudo | Required for persistent localhost access on ports 80/443; otherwise use [foreground forwarding](#run-without-systemd) |

Installation references: [Docker Engine](https://docs.docker.com/engine/install/),
[Minikube](https://minikube.sigs.k8s.io/docs/start/),
[kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/) and
[Helm](https://helm.sh/docs/intro/install/).
New profiles default to Kubernetes **v1.35.9**. Use kubectl within one minor version
of the cluster, for example a 1.35.x or 1.36.x client, as required by the
[kubectl compatibility guidance](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/#before-you-begin).
If using Docker Desktop with WSL2, enable integration for your distribution in
Settings → Resources → WSL Integration. See [Docker's WSL guide](https://docs.docker.com/desktop/features/wsl/).

Minikube is allocated **2 CPUs and 3900 MiB of RAM**. Leave additional memory for
the host and Docker builds. Node.js, Go and NGINX do not need to be installed on
the host. The script downloads Trivy if a scanner is not already available.

## First-time setup

Run all commands from the repository root, the directory containing `Chart.yaml`.
Use your normal user; only the forwarding service installation requires sudo.
Complete each step successfully before continuing.

### 1. Check prerequisites

```bash
bash scripts/setup-local.sh --check
```

Expected result: `Prerequisites passed`. This checks local tools and Docker access
without deploying the application. It does not install missing prerequisites or
verify that every later download and vulnerability scan will succeed.

### 2. Create the environment and deploy

```bash
bash scripts/setup-local.sh
```

The first run can take several minutes. The script performs these steps:

1. Creates or starts the `http-echo-secure` Minikube profile with Calico, then waits for the node and network to be ready. An existing healthy profile is reused.
2. Builds and scans the application image, then loads it into Minikube.
3. Creates the `http-echo` and `nginx-ingress` namespaces with restricted Pod Security settings.
4. Creates or reuses the local TLS certificate and stores it in a Kubernetes Secret.
5. Enables metrics-server so the HPA can read resource metrics.
6. Pulls and scans the official NGINX Alpine image, then installs the controller with its scoped permissions.
7. Deploys the application using `helm upgrade --install`, waits for readiness and runs the Helm, NetworkPolicy and HTTPS checks.
8. Installs and starts `http-echo-ingress.service`, which forwards localhost ports 80/443 to NGINX. This step may request your sudo password.

You do not need to deploy the application with Helm separately. Successful setup
ends with `Local environment and application verified.` A failed step stops the
script; Helm deployment failures use rollback behavior for the installed Helm
version. Earlier successful setup steps are not rolled back as one transaction.

The controller is the official **F5 NGINX Ingress Controller 5.6.3-alpine**, with
Helm chart **2.7.3**. It is a separate project from the community
`kubernetes/ingress-nginx` controller. Four known HIGH findings are accepted for
this local demo by [the scoped exception policy](ops/nginx-scan-exceptions.json).
New HIGH findings and every CRITICAL finding still block deployment; the
application image has no exceptions. The [recorded scan](docs/nginx-alpine-scan-summary.json)
is dated October 12, 2026, and is not a substitute for the scan during your run.

### 3. Select the context for interactive commands

After setup succeeds:

```bash
kubectl config use-context http-echo-secure
kubectl --context=http-echo-secure get nodes
```

Expect the node to be `Ready`. The setup scripts target this context explicitly
and preserve your existing default context. After deleting and recreating a
cluster, that default may be empty. `use-context` selects the project for later
commands that omit `--context`; it changes your current kubectl context.
See the [kubectl command reference](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_config/kubectl_config_use-context/).

## Verify and access the application

Check the deployed resources:

```bash
kubectl --context=http-echo-secure -n http-echo get pods,services,ingress,hpa
kubectl --context=http-echo-secure -n nginx-ingress get pods,services
```

Expect the application and controller Pods to be `Running` and ready. The
`http-echo-test-connection` Pod is a one-time Helm test: `Completed` means success.
Its logs remain available until the next Helm test replaces it. HPA metrics may
initially show `<unknown>` while metrics-server collects samples.

### HTTPS with curl

This command verifies the certificate and hostname without editing DNS or hosts files:

```bash
curl --fail --silent --show-error --max-time 15 --noproxy '*' \
  --cacert .local/http-echo-secure/tls/tls.crt \
  --resolve http-echo.k8s-server.local:443:127.0.0.1 \
  --write-out '\nHTTP %{http_code}\n' \
  https://http-echo.k8s-server.local/
```

Expect a JSON response followed by `HTTP 200`. The JSON should describe `GET /`
and include `x-forwarded-proto: https`. The application's `protocol: http` field
represents the internal connection from NGINX to the application; TLS terminates
at NGINX. Use synthetic request data because bodies and query parameters are echoed.

If `http-echo.k8s-server.local` already resolves to `127.0.0.1` in the environment
running curl (for example, through `/etc/hosts` in Linux/WSL), you can use this
shorter command from the repository root:

```bash
curl --cacert .local/http-echo-secure/tls/tls.crt https://http-echo.k8s-server.local/
```

`--cacert` uses the local certificate to verify the HTTPS connection. If name
resolution is not configured, use the `--resolve` example above.

### Browser access

Add this entry to the hosts file on the machine running the browser:

```text
127.0.0.1 http-echo.k8s-server.local
```

- Windows: `C:\Windows\System32\drivers\etc\hosts`, edited as Administrator.
- Linux: `/etc/hosts`, edited with the required permissions.

Open **https://http-echo.k8s-server.local/**. Use `127.0.0.1` for this setup because
access is through local port-forwarding. The browser will show a certificate
warning until you explicitly trust your generated public certificate,
`.local/http-echo-secure/tls/tls.crt`, in the relevant OS/browser certificate store.
The script does not modify that trust store. Keep `tls.key` private.

Certificates last 90 days and are renewed during setup when fewer than seven days
remain. If the certificate changes, update the browser's trust accordingly.
The curl command above uses the generated certificate directly and does not need `-k`.

## Run without systemd

Use this alternative if systemd is unavailable or you prefer a foreground
forwarder. It does not install or update a persistent service.

```bash
INSTALL_FORWARDER=0 bash scripts/setup-local.sh --check
INSTALL_FORWARDER=0 bash scripts/setup-local.sh
```

After successful setup, select the context and start forwarding:

```bash
kubectl config use-context http-echo-secure
bash scripts/forward-local.sh
```

Leave this terminal running. From another terminal in the repository root:

```bash
curl --fail --silent --show-error --max-time 15 --noproxy '*' \
  --cacert .local/http-echo-secure/tls/tls.crt \
  --connect-to http-echo.k8s-server.local:443:127.0.0.1:8443 \
  --write-out '\nHTTP %{http_code}\n' \
  https://http-echo.k8s-server.local/
```

The browser URL in this mode is **https://http-echo.k8s-server.local:8443/**, with
the same hosts entry and certificate trust. Access HTTPS directly: the HTTP
redirect on port 8080 points to the standard HTTPS port 443, not 8443.
`Ctrl+C` stops forwarding; the cluster continues running.

To install or repair the persistent service later, when systemd is available:

```bash
bash scripts/install-forwarding-service.sh
```

## Stop, restart or recreate the environment

### Stop and preserve the cluster

For a setup using the persistent service:

```bash
sudo systemctl stop http-echo-ingress.service
minikube -p http-echo-secure stop
```

For foreground access, stop the forwarder with `Ctrl+C` and run only the Minikube
command. This preserves the cluster's state.

### Restart an existing cluster

Start Docker first. Then, for the persistent service:

```bash
minikube -p http-echo-secure start --keep-context
kubectl config use-context http-echo-secure
sudo systemctl restart http-echo-ingress.service
```

For foreground access, replace the systemd command with
`bash scripts/forward-local.sh`. Then repeat the HTTPS check above.

### Recreate after deleting the cluster

**Deleting the profile removes its Kubernetes resources and data stored inside
that cluster.** The command below targets only `http-echo-secure`.
See [Minikube's delete reference](https://minikube.sigs.k8s.io/docs/commands/delete/).

If the cluster still exists and you intend to replace it:

```bash
sudo systemctl stop http-echo-ingress.service
minikube -p http-echo-secure delete
```

Skip the systemd command if no persistent service is installed. If you already
deleted the cluster, start here:

```bash
bash scripts/setup-local.sh --check
bash scripts/setup-local.sh
```

After setup succeeds:

```bash
kubectl config use-context http-echo-secure
kubectl --context=http-echo-secure -n http-echo get pods
kubectl --context=http-echo-secure -n nginx-ingress get pods
```

For a system without systemd, follow [Run without systemd](#run-without-systemd)
instead. Recreating the cluster keeps repository files, `.local/` certificates,
the hosts entry, and the host's Docker cache. Reusing an unchanged certificate
preserves existing browser trust; this is a fresh cluster, not a purge of host data.

### Apply application or chart changes

Rerun `bash scripts/setup-local.sh`, using `INSTALL_FORWARDER=0` if that is your
chosen access mode. It rebuilds/scans the image and upgrades the same Helm releases.
Use the same Minikube profile as the original setup.

## Troubleshooting

| Symptom | Action |
|---|---|
| `localhost:8080 ... connection refused` from kubectl | Run `kubectl config get-contexts`, then `kubectl config use-context http-echo-secure`. If the context is absent, complete setup first. Run kubectl as your normal user, without sudo; check that `KUBECONFIG` points to the intended configuration. |
| A configured Kubernetes API endpoint is unreachable | Check `docker info` and `minikube -p http-echo-secure status`. Start Docker and the existing profile if stopped. |
| A prerequisite is missing or Docker access fails | Resolve the error reported by `bash scripts/setup-local.sh --check` in the same Linux/WSL terminal. |
| systemd is unavailable | Use `INSTALL_FORWARDER=0` and the foreground forwarder. |
| Port 80 or 443 is already in use | Identify the existing listener or use foreground forwarding on 8080/8443. |
| HTTPS verification passes but localhost port 443 fails | Check the persistent forwarding service with the commands below. |
| curl succeeds but the browser fails | Check the hosts file and certificate trust on the machine running the browser. |
| A vulnerability scan blocks setup | Read `.local/http-echo-secure/application-scan.json` or `ingress-scan.json`. Review/update the affected image or dependency; existing exceptions apply only to the reviewed findings and digest. |
| `http-echo-test-connection` shows `Completed` | This is the expected result of a successful Helm test. Inspect its logs below. |
| Git shows `detached HEAD` | Deployment still works. For further edits and assignment submission, create a local branch, for example `git switch -c solution`. |

Useful diagnostics:

```bash
minikube -p http-echo-secure status
kubectl --context=http-echo-secure -n http-echo logs deployment/http-echo --tail=100
kubectl --context=http-echo-secure -n nginx-ingress logs deployment/nginx-ingress-controller --tail=100
kubectl --context=http-echo-secure -n http-echo logs http-echo-test-connection
kubectl --context=http-echo-secure -n http-echo get events --sort-by=.metadata.creationTimestamp
bash scripts/verify-https.sh
```

`verify-https.sh` uses temporary local ports 18080/18443 to test HTTP redirection,
TLS verification and the application response independently of the persistent service.
It cleans up its temporary forwarding process on exit. For the persistent service:

```bash
systemctl status http-echo-ingress.service --no-pager
journalctl -u http-echo-ingress.service -n 50 --no-pager
```

If the only failed setup step was installing the systemd service, rerun
`bash scripts/install-forwarding-service.sh` after resolving the reported issue.

## Configuration and project files

All examples use the default profile `http-echo-secure`. The scripts support
`MINIKUBE_PROFILE` for a separate profile; set it consistently for subsequent
runs and adjust the context names and `.local/<profile>/` paths in commands.
An existing profile must use Calico and must not contain the community
ingress-nginx deployment. The single systemd service forwards to the profile
selected when it is installed.

| Path | Purpose |
|---|---|
| `scripts/setup-local.sh` | Local setup, deployment and verification |
| `scripts/build-image.sh` | Build and scan the application image |
| `scripts/install-ingress.sh` | Pull/scan and install the official NGINX controller |
| `scripts/forward-local.sh` | Foreground forwarding; `HTTP_PORT` and `HTTPS_PORT` override 8080/8443 |
| `scripts/install-forwarding-service.sh` | Render and install the persistent forwarding service |
| `values.yaml`, `templates/` | Application resources, routing, autoscaling and security settings |
| `ops/nginx-values.yaml`, `ops/nginx-rbac.yaml` | NGINX settings and Kubernetes permissions |
| `ops/nginx-scan-exceptions.json` | Reviewed controller scan exceptions |
| `values-production.yaml` | Production overrides requiring a registry image digest and multiple nodes |
| `image/`, `tests/` | Application build sources and automated checks |
| `.local/` | Generated certificates, image metadata, scan reports and downloaded tools/charts; excluded from Git and Helm packages |

Preserve `.local/<profile>/tls/`, `image-ref` and `image-values.yaml` for the active
profile. Keep `image/package-lock.json` for reproducible dependency installation.
Old logs and unused downloaded charts can be removed separately; deleting all of
`.local/` discards the local certificate and its private key.

## Additional checks and deployment scope

Run the application integration and network checks independently:

```bash
helm test http-echo --kube-context http-echo-secure -n http-echo --logs
bash scripts/test-network-policy.sh
bash scripts/verify-https.sh
```

For automated chart, scan-policy and image tests:

```bash
helm lint .
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```

The tests require PyYAML in the selected Python environment. Image tests also
require Docker and the `http-echo-local:hardened` image produced by setup or
`bash scripts/build-image.sh`.

For an optional local load measurement:

```bash
BENCHMARK_SECONDS=90 bash scripts/benchmark.sh
```

The default is 30 seconds and 8 clients; supported limits are 1–120 seconds and
1–16 clients (`BENCHMARK_CONCURRENCY`). Each run overwrites
`.local/<profile>/benchmark.json`. Results include port-forward and shared-host
overhead. Historical validation and measurement results are recorded in
[docs/validation-results.json](docs/validation-results.json).

This setup is for a local demonstration. Production requires a registry image
digest, a trusted certificate with renewal, multiple worker nodes, redundant
ingress controllers, monitoring and load testing. The known controller findings
also require a fixed image or a separate production risk review.
