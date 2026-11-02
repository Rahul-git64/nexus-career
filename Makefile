.PHONY: up down build logs ps migrate makemigrations shell test clean \
        image kind-up kind-down k8s-secret k8s-apply k8s-delete k8s-status k8s-logs k8s-forward k8s-all

IMAGE ?= nexus-career-backend:latest
KIND_CLUSTER ?= nexus
NS ?= nexus

# ===== Docker Compose =====
up:
	docker compose up --build

down:
	docker compose down

build:
	docker compose build

logs:
	docker compose logs -f

ps:
	docker compose ps

migrate:
	docker compose exec backend python manage.py migrate

makemigrations:
	docker compose exec backend python manage.py makemigrations

shell:
	docker compose exec backend python manage.py shell

test:
	docker compose exec backend python manage.py test

clean:
	@echo "WARNING: this deletes the local database volume."
	docker compose down -v

# ===== Kubernetes (local kind cluster) =====
image:
	docker build -t $(IMAGE) ./backend

kind-up:
	kind create cluster --name $(KIND_CLUSTER)

kind-down:
	kind delete cluster --name $(KIND_CLUSTER)

# Creates the Secret from your local .env (never committed)
k8s-secret:
	kubectl create namespace $(NS) --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n $(NS) create secret generic nexus-secrets --from-env-file=.env \
		--dry-run=client -o yaml | kubectl apply -f -

k8s-apply: image
	kind load docker-image $(IMAGE) --name $(KIND_CLUSTER)
	kubectl apply -k k8s/
	kubectl -n $(NS) rollout restart deployment/backend

k8s-delete:
	kubectl delete -k k8s/ --ignore-not-found

k8s-status:
	kubectl -n $(NS) get pods,svc,ingress

k8s-logs:
	kubectl -n $(NS) logs -l app=backend -f --tail=100

k8s-forward:
	kubectl -n $(NS) port-forward svc/backend 8000:80

# One-shot: cluster + secret + deploy
k8s-all: kind-up k8s-secret k8s-apply
