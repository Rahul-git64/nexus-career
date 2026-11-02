#!/usr/bin/env bash
# Nexus Career - Docker + Kubernetes demo run (for team meetings)
#
# Run from anywhere inside the repo, on a branch that has BOTH patches applied
# (0001-fix-backend-startup + 0002-k8s-setup).
#
#   bash scripts/demo.sh            # interactive: press Enter between steps
#   AUTO=1 bash scripts/demo.sh     # no pauses (for a dry run / recording)
#   KEEP=1 bash scripts/demo.sh     # leave the kind cluster running at the end
#
# Needs: docker (running), kubectl, kind, curl, git

set -uo pipefail

IMAGE="nexus-career-backend:latest"
CLUSTER="nexus"
NS="nexus"
PF_PORT=8080
PF_PID=""

# ---------- helpers ----------
B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'

pause() { [[ "${AUTO:-0}" == "1" ]] && sleep 1 || read -r -p "${Y}  [Enter to continue] ${N}" _; }
step()  { echo; echo "${B}${C}==> $*${N}"; }
note()  { echo "${Y}    $*${N}"; }
ok()    { echo "${G}    OK: $*${N}"; }
fail()  { echo "${R}    FAIL: $*${N}"; FAILED=1; }
run()   { echo "${B}\$ $*${N}"; eval "$*"; local rc=$?; [[ $rc -ne 0 ]] && fail "command exited with $rc"; return $rc; }

FAILED=0

pf_stop() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null; PF_PID=""; }

# Port-forward pins to ONE pod, so restart it each time (pods get replaced in this demo)
k8s_health() {
  pf_stop
  kubectl -n "$NS" port-forward svc/backend "$PF_PORT":80 >/dev/null 2>&1 &
  PF_PID=$!
  local out=""
  for _ in $(seq 1 20); do
    out=$(curl -s --max-time 2 -H "Host: localhost" "http://127.0.0.1:${PF_PORT}/health/") && [[ -n "$out" ]] && break
    sleep 1
  done
  pf_stop
  echo "${B}\$ curl http://localhost:${PF_PORT}/health/  (via kubectl port-forward)${N}"
  if [[ "$out" == *ok* ]]; then ok "response: $out"; else fail "no healthy response"; fi
}

cleanup() {
  pf_stop
  if [[ "${KEEP:-0}" != "1" ]]; then
    echo; step "Cleanup"
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 && note "kind cluster deleted"
    docker compose down >/dev/null 2>&1 && note "compose stack stopped"
  else
    note "KEEP=1 set: cluster '$CLUSTER' left running (make kind-down to remove)"
  fi
}
trap cleanup EXIT

# ---------- preflight ----------
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "Run this inside the repo"; exit 1; }

step "Preflight"
for t in docker kubectl kind curl git; do
  command -v "$t" >/dev/null 2>&1 && ok "$t found" || { fail "$t is not installed"; exit 1; }
done
docker info >/dev/null 2>&1 && ok "docker daemon running" || { fail "docker daemon is not running"; exit 1; }
[[ -d k8s && -f k8s/kustomization.yaml ]] && ok "k8s/ manifests present" || { fail "k8s/ missing: apply 0002-k8s-setup.patch"; exit 1; }
grep -q "health" backend/config/urls.py && ok "/health/ endpoint present" || { fail "/health/ missing: apply 0001-fix-backend-startup.patch"; exit 1; }

if [[ ! -f .env ]]; then
  pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
  sk=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)
  printf 'POSTGRES_PASSWORD=%s\nDJANGO_SECRET_KEY=%s\n' "$pw" "$sk" > .env
  ok ".env created with random demo credentials (git-ignored, not shown)"
else
  ok ".env already exists (not shown)"
fi
pause

# ================= PART 1: DOCKER =================
step "PART 1 - Docker: build the backend image"
note "Multi-stage build, runs gunicorn as a non-root user (uid 1000)"
run "docker build -t $IMAGE ./backend"
run "docker images $IMAGE --format 'image: {{.Repository}}:{{.Tag}}   size: {{.Size}}'"
run "docker run --rm --entrypoint id $IMAGE"
pause

step "PART 1 - Docker Compose: app + Postgres"
note "Compose waits for Postgres to be healthy, then starts the backend"
run "docker compose up -d --build --wait"
run "docker compose ps"
echo "${B}\$ curl http://localhost:8000/health/${N}"
out=$(curl -s --max-time 5 http://localhost:8000/health/)
[[ "$out" == *ok* ]] && ok "response: $out" || fail "no healthy response from compose stack"
pause

step "PART 1 - Tear down compose (database volume is kept)"
run "docker compose down"
pause

# ================= PART 2: KUBERNETES =================
step "PART 2 - Kubernetes: create a local cluster with kind"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  note "cluster '$CLUSTER' already exists, reusing it"
else
  run "kind create cluster --name $CLUSTER"
fi
run "kubectl cluster-info --context kind-$CLUSTER"
pause

step "PART 2 - Load the image and create the Secret"
note "The Secret is built from the local .env. It never goes into Git"
run "kind load docker-image $IMAGE --name $CLUSTER"
run "kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -"
run "kubectl -n $NS create secret generic nexus-secrets --from-env-file=.env --dry-run=client -o yaml | kubectl apply -f -"
pause

step "PART 2 - Deploy everything with one command (kustomize)"
note "Postgres StatefulSet + backend Deployment + Services + Ingress + ConfigMap"
run "kubectl apply -k k8s/"
note "Backend init container runs 'migrate' first, then the app starts"
run "kubectl -n $NS rollout status statefulset/db --timeout=180s"
run "kubectl -n $NS rollout status deployment/backend --timeout=240s"
run "kubectl -n $NS get pods,svc,pvc"
k8s_health
pause

step "DEMO A - Self-healing: kill the backend pod"
POD=$(kubectl -n "$NS" get pod -l app=backend -o jsonpath='{.items[0].metadata.name}')
note "Deleting $POD. Kubernetes should replace it automatically"
run "kubectl -n $NS delete pod $POD --wait=false"
run "kubectl -n $NS rollout status deployment/backend --timeout=240s"
run "kubectl -n $NS get pods -l app=backend"
k8s_health
pause

step "DEMO B - Scaling: 1 -> 3 replicas"
run "kubectl -n $NS scale deployment/backend --replicas=3"
run "kubectl -n $NS rollout status deployment/backend --timeout=240s"
run "kubectl -n $NS get pods -l app=backend -o wide"
k8s_health
pause

step "DEMO C - Rolling update, then rollback"
note "Changing an env var triggers a new rollout (same as shipping a new image)"
run "kubectl -n $NS set env deployment/backend DEMO_RELEASE=v2"
run "kubectl -n $NS rollout status deployment/backend --timeout=240s"
run "kubectl -n $NS rollout history deployment/backend"
note "Now roll back to the previous revision"
run "kubectl -n $NS rollout undo deployment/backend"
run "kubectl -n $NS rollout status deployment/backend --timeout=240s"
k8s_health
pause

step "DEMO D - Data survives a database pod restart (PersistentVolume)"
SQL="select count(*) from information_schema.tables where table_schema='public'"
before=$(kubectl -n "$NS" exec db-0 -- psql -U nexus_user -d nexus_career -tAc "$SQL" 2>/dev/null)
note "Tables in the database before: $before"
run "kubectl -n $NS delete pod db-0"
run "kubectl -n $NS wait --for=condition=ready pod/db-0 --timeout=180s"
after=$(kubectl -n "$NS" exec db-0 -- psql -U nexus_user -d nexus_career -tAc "$SQL" 2>/dev/null)
note "Tables in the database after:  $after"
[[ -n "$before" && "$before" == "$after" ]] && ok "same data after the pod was recreated" || fail "table count changed or could not be read"
pause

# ---------- summary ----------
echo
if [[ $FAILED -eq 0 ]]; then
  echo "${B}${G}ALL DEMO STEPS PASSED${N}"
else
  echo "${B}${R}SOME STEPS FAILED - scroll up for the FAIL lines${N}"
fi
