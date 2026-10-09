#!/usr/bin/env bash
# One-command setup: kind cluster "demo" + ingress-nginx + image + Helm release "demo".
# Idempotent: safe to run any number of times.
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER_NAME="demo"
NAMESPACE="demo"
RELEASE="demo"
IMAGE_REPO="demo-service"
IMAGE_TAG="${IMAGE_TAG:-0.1.0}"
INGRESS_NGINX_VERSION="controller-v1.11.3"
INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# ---- 0. preflight ----
for bin in docker kind kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing required tool: $bin" >&2; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "docker daemon not reachable" >&2; exit 1; }

# ---- 1. cluster (create or reuse) ----
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "kind cluster '$CLUSTER_NAME' exists, reusing"
else
  for port in 80 443; do
    if ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; then
      echo "host port $port is already in use; kind needs 80/443 for ingress. Free it and re-run." >&2
      exit 1
    fi
  done
  log "creating kind cluster '$CLUSTER_NAME'"
  # - host ports 80/443 -> ingress controller on the control-plane node
  # - kubelet syncFrequency 10s (default 1m): a patched ConfigMap reaches the
  #   mounted files, and therefore GET /, within ~10-20s instead of ~60-90s
  kind create cluster --name "$CLUSTER_NAME" --wait 120s --config - <<'KIND'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
kubeadmConfigPatches:
  - |
    kind: KubeletConfiguration
    syncFrequency: 10s
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
KIND
fi
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

# ---- 2. ingress-nginx ----
log "installing ingress-nginx (${INGRESS_NGINX_VERSION})"
kubectl apply -f "$INGRESS_MANIFEST"
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=300s
# the admission webhook only works once its cert jobs have finished
# (guarded: if a job was already cleaned up, there is nothing to wait for)
for job in ingress-nginx-admission-create ingress-nginx-admission-patch; do
  if kubectl -n ingress-nginx get job "$job" >/dev/null 2>&1; then
    kubectl -n ingress-nginx wait --for=condition=complete "job/$job" --timeout=180s
  fi
done

# ---- 3. image build + load ----
log "building image ${IMAGE_REPO}:${IMAGE_TAG}"
docker build -t "${IMAGE_REPO}:${IMAGE_TAG}" service/
log "loading image into kind"
kind load docker-image "${IMAGE_REPO}:${IMAGE_TAG}" --name "$CLUSTER_NAME"
# same tag + IfNotPresent would never pick up a rebuild; pin pods to the image ID
IMAGE_ID="$(docker image inspect --format '{{.Id}}' "${IMAGE_REPO}:${IMAGE_TAG}" | cut -d: -f2 | cut -c1-12)"

# ---- 4. helm release ----
# the webhook endpoint can still lag a few seconds behind the waits above;
# retry instead of failing on "failed calling webhook"
log "installing chart as release '$RELEASE' in namespace '$NAMESPACE'"
for attempt in 1 2 3 4 5; do
  if helm upgrade --install "$RELEASE" ./chart \
       --namespace "$NAMESPACE" --create-namespace \
       --set image.repository="$IMAGE_REPO" \
       --set image.tag="$IMAGE_TAG" \
       --set-string podAnnotations.imageId="$IMAGE_ID" \
       --wait --timeout 180s; then
    break
  fi
  [ "$attempt" -eq 5 ] && { echo "helm install failed after $attempt attempts" >&2; exit 1; }
  echo "helm attempt $attempt failed, retrying in 10s..."
  sleep 10
done

log "done"
cat <<MSG
Verify:
  kubectl -n $NAMESPACE get deploy,pods,svc,ingress
  curl -H 'Host: demo.local' http://localhost/
  curl -i -H 'Host: demo.local' http://localhost/healthz
MSG
