# Enterprise Bot — DevOps take-home

| Part | Where |
|---|---|
| 1. Service + Dockerfile | `service/` (app, tests, `Dockerfile`, `.dockerignore`) |
| 2. Helm chart | `chart/` |
| 3. One-command setup | `setup.sh` |
| 4. Debug lab | `lab/` — fixed `broken-chart/`, `FINDINGS.md`, `part4-session.log` |
| 5. Written question | `ANSWERS.md` |
| CI | `Jenkinsfile` (primary), `.github/workflows/ci.yml` (secondary, see [CI](#ci)) |

## Prerequisites

Ubuntu (or any Linux) with Docker, kind, kubectl, helm. Host ports **80 and 443 must be free**: kind maps them to the ingress controller.

```bash
# kind (pick the current release; v0.24.0 shown)
curl -Lo kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
chmod +x kind && sudo mv kind /usr/local/bin/
# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

## Quick start (acceptance path: kind)

```bash
./setup.sh    # kind cluster "demo" + ingress-nginx + image + release "demo" in namespace "demo"
./setup.sh    # second run: reuses everything, exits 0
```

### Verify

```bash
kubectl -n demo get deploy,pods,svc,ingress            # deployment demo 2/2
curl -H 'Host: demo.local' http://localhost/            # {"app":"demo","pod":"demo-<hash>","version":"0.1.0"}
curl -i -H 'Host: demo.local' http://localhost/healthz  # HTTP/1.1 200

# config change via Helm -> checksum annotation rolls the pods
helm upgrade demo ./chart -n demo --reuse-values --set config.appName=changed
curl -H 'Host: demo.local' http://localhost/

# config change by patching the ConfigMap directly -> no restart
kubectl -n demo patch configmap demo-config -p '{"data":{"APP_NAME":"patched"}}'
sleep 20; curl -H 'Host: demo.local' http://localhost/   # "app":"patched"

# chart renders with overrides
helm lint ./chart
helm template demo ./chart --set replicaCount=3 --set config.appName=x | grep -E 'replicas:|APP_NAME'
```

Optional: add `127.0.0.1 demo.local` to `/etc/hosts`, then `curl http://demo.local/`.

### Docker only

```bash
docker build -t demo-service:0.1.0 service/
docker run --rm -p 8080:8080 -e APP_NAME=local -e VERSION=1.0.0 demo-service:0.1.0
curl localhost:8080/ ; curl -i localhost:8080/healthz
docker run --rm --entrypoint id demo-service:0.1.0     # uid=10001, not root
```

### Unit tests

```bash
python3 -m venv .venv && .venv/bin/pip install -r service/requirements-dev.txt
cd service && ../.venv/bin/pytest -q
```

### Local alternative: Minikube (not the acceptance path)

`setup.sh` targets kind on purpose, because that's what the assignment grades against. To try the same chart on Minikube:

```bash
minikube start
minikube addons enable ingress
docker build -t demo-service:0.1.0 service/
minikube image load demo-service:0.1.0
helm upgrade --install demo ./chart -n demo --create-namespace --wait
curl -H 'Host: demo.local' "http://$(minikube ip)/"
```

On Minikube the kubelet keeps its default sync period, so a ConfigMap patch takes ~60–90 s to reach `GET /`. The lab (`lab/scenario.sh`) works on either cluster.

## How `setup.sh` works

1. **Preflight:** checks that docker/kind/kubectl/helm exist and the Docker daemon answers.
2. **Cluster:** reuses `demo` if `kind get clusters` lists it. Otherwise checks that ports 80/443 are free and creates it with port mappings, the `ingress-ready` node label, and kubelet `syncFrequency: 10s` (see "Service" below).
3. **ingress-nginx:** `kubectl apply` of the pinned kind manifest (`controller-v1.11.3`), then waits for the controller rollout and the admission-webhook cert jobs.
4. **Image:** `docker build`, then `kind load docker-image`. The tag stays `0.1.0`, so the image ID goes into a pod annotation. Without that, a rebuilt image with the same tag would never roll out.
5. **Release:** `helm upgrade --install demo ./chart -n demo --create-namespace --wait`, retried up to 5 times in case the webhook is still settling.

**Idempotency:** every step is "create if missing" or declarative (`kubectl apply`, `helm upgrade --install`), so a second run changes nothing and exits 0.

## Design notes

**Service** (`service/app.py`): Flask behind gunicorn (2 sync workers). `APP_NAME`/`VERSION` are read per request: first from files in `/etc/app-config` (the ConfigMap mounted as a volume), then from env vars, then defaults. Env vars alone would go stale when the ConfigMap is patched, because a container's environment is fixed at start. The kubelet refreshes mounted ConfigMap files in place, so `GET /` follows a patch without a restart. How fast depends on the kubelet sync period, which is why the kind cluster sets it to 10 s. Outside Kubernetes there is no file, so `docker run -e` works as expected.

**Dockerfile:** builder stage installs pinned deps into a venv; runtime stage copies only the venv and `app.py`. Base image pinned to `python:3.12.7-slim-bookworm`. Runs as UID 10001 (numeric, so `runAsNonRoot` can check it). `.dockerignore` is an allow-list: only `app.py` and `requirements.txt` enter the build context. All runtime deps, including transitive ones, are pinned in `requirements.txt`.

**Chart:** the ConfigMap is used twice, via `envFrom` (the env-var contract) and as a volume (live updates). A `checksum/config` annotation rolls pods on `helm upgrade` config changes. Pods run with a read-only root FS, all capabilities dropped, seccomp `RuntimeDefault`, and no service-account token. `/tmp` is a small in-memory `emptyDir` for gunicorn's worker heartbeat files. Every harness key (`replicaCount`, `image.*`, `config.*`, `ingress.host`, `resources`) comes from `values.yaml`; nothing is hardcoded in templates.

## Resources and why

| | request | limit |
|---|---|---|
| CPU | 50m | 250m |
| Memory | 64Mi | 128Mi |

- **Memory:** gunicorn master + 2 workers measured ~52 MiB PSS on a Linux host after 200 requests (outside a container; in-pod usage not yet measured). A 64Mi request matches steady state so scheduling is honest. Memory is not compressible: going over the limit means OOMKill, so the 128Mi limit leaves ~2.5x headroom rather than sitting near the request.
- **CPU:** idle service with near-zero baseline, so 50m is enough to schedule it on a small kind node. The 250m limit lets startup and bursts through; exceeding a CPU limit only throttles, it never kills.
- **Trade-off:** numbers are sized for a toy service on a laptop. Real values should come from `kubectl top` (metrics-server) under load.

## CI

**Primary: `Jenkinsfile`** (Declarative Pipeline). Stages: Checkout → Tooling check → Static checks (in parallel: `bash -n`/shellcheck on `setup.sh`; `helm lint` plus render assertions for defaults and overrides) → Unit tests (pytest, JUnit report) → Build image → Container smoke test (non-root UID, `/healthz`, `GET /` follows env) → Trivy scan (fails on fixable HIGH/CRITICAL) → optional Push. Reports (`reports/pytest.xml`, `reports/trivy.txt`) are archived.

Requirements for Jenkins:
- **Jenkins plugins:** Pipeline, Git, JUnit, Timestamper; Credentials Binding only for the optional push.
- **Ubuntu agent:** `docker`, `helm`, `python3`, `python3-venv`, `curl`, `git`; `shellcheck` optional. The Jenkins user must be in the `docker` group: `sudo usermod -aG docker jenkins && sudo systemctl restart jenkins`.
- **Trivy:** runs as the pinned `aquasec/trivy` container against the host Docker socket, so it doesn't need installing. Its vulnerability DB is cached in a named volume.
- **Credentials:** none needed. If you tick `PUSH_IMAGE`, the pipeline uses a Jenkins *Username with password* credential with ID `registry-creds`. Nothing secret lives in the repo.

To run it: New Item → Pipeline → "Pipeline script from SCM" → Git, this repo's URL, branch `main`, script path `Jenkinsfile` → Build Now.

**Secondary: `.github/workflows/ci.yml`.** The optional bonus in the brief literally names "GitHub Actions or `.gitlab-ci.yml`", and Jenkins doesn't match that wording. So a GitHub Actions workflow with the same core checks is kept for that bonus. Jenkins is the pipeline I'd actually run.

## What I deliberately skipped (and the risk)

- **TLS on the Ingress:** plain HTTP. Fine on a laptop, unacceptable in production.
- **HPA / PodDisruptionBudget / anti-affinity:** 2 fixed replicas on one node; a node drain takes both down.
- **NetworkPolicy:** any pod can reach the service.
- **Registry, signing, digest pinning:** the image only exists inside kind; no provenance. The base image is pinned by tag, not by digest.
- **Base image freshness:** `3.12.7-slim-bookworm` is an older patch tag that no longer gets rebuilt, so Trivy may find fixable HIGH CVEs and fail the pipeline. That is the gate doing its job; the fix is bumping to the newest `3.12.x-slim-bookworm` tag.
- **Instant config propagation:** relies on the kubelet sync loop (~10–20 s on this kind cluster, ~60–90 s by default). A watcher such as Stakater Reloader, or reading the ConfigMap via the API, would be instant but adds RBAC and moving parts.
- **Chart tests:** no `helm unittest`; render assertions live in the Jenkinsfile instead.
- **End-to-end CI:** CI doesn't spin up kind and run `setup.sh`; that is verified manually.

## Production-ready changes

- Push to a registry, tag by git SHA, sign (cosign), deploy by digest.
- TLS via cert-manager, and Gateway API instead of the end-of-life ingress-nginx (see `ANSWERS.md`).
- HPA, PDB, topology spread across nodes and zones.
- Split liveness (process alive) and readiness (dependencies OK) once the service has dependencies.
- `/metrics` endpoint, alerts, structured JSON logs.
- NetworkPolicies; resource numbers from load tests.
- GitOps (Argo CD / Flux) for deploys; an end-to-end kind job in CI.

## Part 4 — debug lab

See `lab/FINDINGS.md` and `lab/part4-session.log`.

## How I used AI

- **Tool:** Claude (Anthropic), in the claude.ai chat interface.
- **What it produced:** first versions of `service/` (app, unit tests, Dockerfile), `chart/`, `setup.sh`, the `Jenkinsfile`, the GitHub Actions workflow, this README and `ANSWERS.md`. It also reviewed everything against `ASSIGNMENT.md` in a second pass.
- **What it tested in its sandbox:** unit tests, gunicorn with the container's CMD flags, `shellcheck`, a Groovy parse of the Jenkinsfile, and an *approximate* chart render with a stand-in renderer (not real Helm). Real `helm`, `docker`, `kind` and Jenkins weren't available there, so those were run on my own Ubuntu VM.
- **Corrections during the review pass:**
  - Env-only config would go stale on a ConfigMap patch, so the app now reads the mounted file first.
  - `setup.sh` now waits for the ingress-nginx admission webhook and checks for port conflicts.
  - The kind kubelet sync period was shortened.
  - Transitive Python deps were pinned.
  - CI moved to Jenkins at my request.
- **Part 4:** Claude read the broken chart's YAML and gave me a list of *suspected* defects with diagnostic commands. The investigation itself, every command output in `FINDINGS.md`, and the session recording come from my own cluster; each finding there is one I confirmed on it.
