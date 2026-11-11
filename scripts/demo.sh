#!/usr/bin/env bash
# Nexus Career - Full-Stack Docker + Kubernetes demo run (for team meetings)
#
#   bash scripts/demo.sh            # interactive: press Enter between steps
#   AUTO=1 bash scripts/demo.sh     # no pauses (for a dry run / recording)
#   KEEP=1 bash scripts/demo.sh     # leave the kind cluster running at the end
#
# Needs: docker (running), kubectl, kind, curl, git

set -uo pipefail

BACKEND_IMAGE="nexus-career-backend:latest"
FRONTEND_IMAGE="nexus-career-frontend:latest"
CLUSTER="nexus"
NS="nexus"
PF_BACKEND_PORT=8080
PF_FRONTEND_PORT=5174
PF_PIDS=()

# ---------- helpers ----------
B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'

pause() { [[ "${AUTO:-0}" == "1" ]] && sleep 1 || read -r -p "${Y}  [Enter to continue] ${N}" _; }
step()  { echo; echo "${B}${C}==> $*${N}"; }
note()  { echo "${Y}    $*${N}"; }
ok()    { echo "${G}    OK: $*${N}"; }
fail()  { echo "${R}    FAIL: $*${N}"; FAILED=1; }
run()   { echo "${B}\$ $*${N}"; eval "$*"; local rc=$?; [[ $rc -ne 0 ]] && fail "command exited with $rc"; return $rc; }

FAILED=0

pf_stop() {
  for pid in "${PF_PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  PF_PIDS=()
}

k8s_health() {
  pf_stop
  kubectl -n "$NS" port-forward svc/backend "$PF_BACKEND_PORT":80 >/dev/null 2>&1 &
  PF_PIDS+=($!)
  kubectl -n "$NS" port-forward svc/frontend "$PF_FRONTEND_PORT":80 >/dev/null 2>&1 &
  PF_PIDS+=($!)

  local out=""
  for _ in $(seq 1 20); do
    out=$(curl -s --max-time 2 -H "Host: localhost" "http://127.0.0.1:${PF_BACKEND_PORT}/health/") && [[ -n "$out" ]] && break
    sleep 1
  done
  echo "${B}\$ curl http://localhost:${PF_BACKEND_PORT}/health/  (via kubectl port-forward)${N}"
  if [[ "$out" == *ok* ]]; then ok "backend health: $out"; else fail "no healthy response from backend"; fi

  local opp_out=""
  opp_out=$(curl -s --max-time 5 -H "Host: localhost" "http://127.0.0.1:${PF_BACKEND_PORT}/api/v1/opportunities/")
  if [[ "$opp_out" == *results* ]]; then ok "seeded opportunities API active"; else fail "opportunities API check failed"; fi

  local fe_out=""
  for _ in $(seq 1 15); do
    fe_out=$(curl -s --max-time 2 "http://127.0.0.1:${PF_FRONTEND_PORT}/") && [[ -n "$fe_out" ]] && break
    sleep 1
  done
  if [[ "$fe_out" == *"<div id=\"root\">"* ]]; then ok "frontend serving React SPA on port ${PF_FRONTEND_PORT}"; else fail "frontend check failed"; fi
  pf_stop
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
[[ -d k8s && -f k8s/kustomization.yaml ]] && ok "k8s/ manifests present" || { fail "k8s/ missing"; exit 1; }
grep -q "health" backend/config/urls.py && ok "/health/ endpoint present" || { fail "/health/ missing"; exit 1; }

if [[ ! -f .env ]]; then
  cp .env.example .env
  ok ".env created from .env.example"
else
  ok ".env already exists"
fi
pause

# ================= PART 1: DOCKER =================
step "PART 1 - Docker: build backend & frontend images"
note "Multi-stage backend build (gunicorn, uid 1000) + React/Vite frontend image (uid 1000)"
run "docker build -t $BACKEND_IMAGE ./backend"
run "docker build -t $FRONTEND_IMAGE ./frontend"
run "docker images --filter=reference='nexus-career-*' --format 'image: {{.Repository}}:{{.Tag}}   size: {{.Size}}'"
run "docker run --rm --entrypoint id $BACKEND_IMAGE"
pause

step "PART 1 - Docker Compose: Postgres + Backend (migrated & seeded) + Frontend"
run "docker compose up -d --build --wait"
run "docker compose ps"
echo "${B}\$ curl http://localhost:8000/health/${N}"
out=$(curl -s --max-time 5 http://localhost:8000/health/)
[[ "$out" == *ok* ]] && ok "health: $out" || fail "no healthy response from compose stack"
echo "${B}\$ curl http://localhost:8000/api/v1/opportunities/${N}"
opp=$(curl -s --max-time 5 http://localhost:8000/api/v1/opportunities/)
[[ "$opp" == *NovaTech* ]] && ok "seeded opportunities returned from /api/v1/opportunities/" || fail "seeded opportunities missing"
echo "${B}\$ curl -I http://localhost:5173/${N}"
fe=$(curl -s --max-time 5 http://localhost:5173/)
[[ "$fe" == *"<div id=\"root\">"* ]] && ok "frontend reachable on http://localhost:5173" || fail "frontend not reachable"
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

step "PART 2 - Load images and create the Secret"
run "kind load docker-image $BACKEND_IMAGE --name $CLUSTER"
run "kind load docker-image $FRONTEND_IMAGE --name $CLUSTER"
run "kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -"
run "kubectl -n $NS create secret generic nexus-secrets --from-env-file=.env --dry-run=client -o yaml | kubectl apply -f -"
pause

step "PART 2 - Deploy full-stack app with kustomize"
note "Postgres StatefulSet + Backend Deployment (initContainer: migrate + seed_demo) + Frontend Deployment + Services + Ingress"
run "kubectl apply -k k8s/"
run "kubectl -n $NS rollout status statefulset/db --timeout=180s"
run "kubectl -n $NS rollout status deployment/backend --timeout=240s"
run "kubectl -n $NS rollout status deployment/frontend --timeout=240s"
run "kubectl -n $NS get pods,svc,pvc"
k8s_health
pause

step "DEMO A - Self-healing: kill the backend pod"
POD=$(kubectl -n "$NS" get pod -l app=backend -o jsonpath='{.items[0].metadata.name}')
note "Deleting $POD. Kubernetes replaces it automatically"
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
run "kubectl -n $NS set env deployment/backend DEMO_RELEASE=v2"
run "kubectl -n $NS rollout status deployment/backend --timeout=240s"
run "kubectl -n $NS rollout history deployment/backend"
run "kubectl -n $NS rollout undo deployment/backend"
run "kubectl -n $NS rollout status deployment/backend --timeout=240s"
k8s_health
pause

step "DEMO D - Data survives a database pod restart (PersistentVolume)"
SQL="select count(*) from opportunities;"
before=$(kubectl -n "$NS" exec db-0 -- psql -U nexus_user -d nexus_career -tAc "$SQL" 2>/dev/null)
note "Seeded opportunities in database before restart: $before"
run "kubectl -n $NS delete pod db-0"
run "kubectl -n $NS wait --for=condition=ready pod/db-0 --timeout=180s"
after=$(kubectl -n "$NS" exec db-0 -- psql -U nexus_user -d nexus_career -tAc "$SQL" 2>/dev/null)
note "Seeded opportunities in database after restart:  $after"
[[ -n "$before" && "$before" == "$after" ]] && ok "same data ($after opportunities) after the pod was recreated" || fail "data count changed or could not be read"
pause

# ---------- summary ----------
echo
if [[ $FAILED -eq 0 ]]; then
  echo "${B}${G}ALL FULL-STACK DEMO STEPS PASSED${N}"
else
  echo "${B}${R}SOME STEPS FAILED - scroll up for the FAIL lines${N}"
fi
