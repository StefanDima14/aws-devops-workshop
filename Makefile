# =============================================================================
# AWS DevOps Workshop — task runner
#
# The SAME app + monitoring stack, runnable two ways so you can feel the
# difference between the two runtimes:
#
#   make docker-up   → Docker Compose  (one host, `docker run` under the hood)
#   make k8s-up      → Kubernetes      (OrbStack's built-in cluster)
#
# The application image and the Grafana dashboard are identical in both — only
# the *runtime* changes. The k8s-* targets are built to teach that difference:
# run `make k8s-explain` for a side-by-side, and `make k8s-heal` / `make
# k8s-scale` to watch Kubernetes do things Compose simply can't.
#
# Run `make` on its own to list every target.
# =============================================================================

# App base URL — the same in both runtimes, so the stress-* helpers work for both.
APP ?= http://localhost:8080
# Kubernetes settings.
# We deploy to OrbStack's built-in cluster so every object shows up in the
# OrbStack ▸ Kubernetes UI. Override to use another cluster, e.g.
#   make k8s-up K8S_CONTEXT=docker-desktop
K8S_CONTEXT ?= orbstack
K8S_NS ?= workshop
IMAGE ?= workshop-app:local
# SAFETY: pin every kubectl call to the chosen context. This guarantees the
# teaching commands (delete pod, scale, ...) NEVER touch another cluster you
# happen to have configured (e.g. a real EKS in your kubeconfig).
KCTL := kubectl --context $(K8S_CONTEXT)

.DEFAULT_GOAL := help

# --- Help ---------------------------------------------------------------------
# Self-documenting: any target with a "## comment" shows up in `make help`,
# grouped by the "##@" section headers below.
.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"} \
	  /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next} \
	  /^[a-zA-Z0-9_-]+:.*?##/ {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

##@ Docker (Compose) — the single-host runtime
.PHONY: docker-up
docker-up: ## Build + start the full stack with Docker Compose
	docker compose up -d --build
	@$(MAKE) --no-print-directory docker-urls

.PHONY: docker-down
docker-down: ## Stop the Compose stack (keeps volumes/history)
	docker compose down

.PHONY: docker-clean
docker-clean: ## Stop the Compose stack AND delete its volumes
	docker compose down -v

.PHONY: docker-ps
docker-ps: ## Show the status of every Compose service
	docker compose ps

.PHONY: docker-logs
docker-logs: ## Tail logs from all Compose services (Ctrl-C to stop)
	docker compose logs -f

.PHONY: docker-urls
docker-urls: ## Print the URLs of every UI (Docker)
	@echo ""
	@echo "  App          $(APP)"
	@echo "  Ops Console  $(APP)/panel"
	@echo "  Grafana      http://localhost:3000   (dashboard: 'App Observability — Workshop')"
	@echo "  Prometheus   http://localhost:9090"
	@echo "  cAdvisor     http://localhost:8081"
	@echo ""

##@ Kubernetes — the orchestrated runtime (via OrbStack)
.PHONY: k8s-preflight
k8s-preflight: ## Check that docker + kubectl + the cluster are reachable
	@command -v docker  >/dev/null || { echo "❌ docker not found";  exit 1; }
	@command -v kubectl >/dev/null || { echo "❌ kubectl not found (brew install kubectl)"; exit 1; }
	@docker info >/dev/null 2>&1   || { echo "❌ Docker daemon is not running (open OrbStack)"; exit 1; }
	@$(KCTL) get nodes >/dev/null 2>&1 || { echo "❌ Cluster '$(K8S_CONTEXT)' unreachable. In OrbStack, enable Kubernetes (Settings ▸ Kubernetes)."; exit 1; }
	@echo "✅ docker, kubectl and the '$(K8S_CONTEXT)' cluster are ready."

.PHONY: k8s-up
k8s-up: k8s-preflight ## Deploy the whole stack to OrbStack's Kubernetes
	# 1. Build the app image. OrbStack SHARES its image store with Kubernetes, so
	#    a locally-built image is immediately usable by the cluster — no registry
	#    push and no image side-loading needed. (A real cloud cluster pulls from ECR.)
	docker build -t "$(IMAGE)" ./app
	# 2. Namespace — a virtual cluster-within-the-cluster to group our objects.
	$(KCTL) apply -f k8s/00-namespace.yaml
	# 3. Config as ConfigMaps. Compose *bind-mounts* files from disk; Kubernetes
	#    stores config as first-class API objects. We build them from the very
	#    same files under monitoring/, so there is one source of truth.
	$(KCTL) -n $(K8S_NS) create configmap prometheus-config \
	  --from-file=monitoring/prometheus/prometheus.yml \
	  --dry-run=client -o yaml | $(KCTL) apply -f -
	$(KCTL) -n $(K8S_NS) create configmap loki-config \
	  --from-file=monitoring/loki/loki-config.yml \
	  --dry-run=client -o yaml | $(KCTL) apply -f -
	$(KCTL) -n $(K8S_NS) create configmap grafana-datasources \
	  --from-file=monitoring/grafana/provisioning/datasources/ \
	  --dry-run=client -o yaml | $(KCTL) apply -f -
	$(KCTL) -n $(K8S_NS) create configmap grafana-dashboard-provider \
	  --from-file=monitoring/grafana/provisioning/dashboards/ \
	  --dry-run=client -o yaml | $(KCTL) apply -f -
	$(KCTL) -n $(K8S_NS) create configmap grafana-dashboards \
	  --from-file=monitoring/grafana/dashboards/ \
	  --dry-run=client -o yaml | $(KCTL) apply -f -
	# 4. The workloads themselves (Deployments, Services, DaemonSets, RBAC).
	$(KCTL) apply -f k8s/
	# 5. Wait for the app to become Ready, then print the URLs.
	$(KCTL) -n $(K8S_NS) rollout status deployment/app --timeout=120s
	@$(MAKE) --no-print-directory k8s-urls

.PHONY: k8s-down
k8s-down: ## Remove our stack from the cluster (leaves OrbStack's cluster intact)
	# Deleting our objects only — NOT the cluster. `-f k8s/` covers the namespace
	# (which cascades every namespaced object, including the generated ConfigMaps)
	# plus the cluster-scoped promtail RBAC.
	$(KCTL) delete -f k8s/ --ignore-not-found

.PHONY: k8s-urls
k8s-urls: ## Print the URLs of every UI (Kubernetes)
	@echo ""
	@echo "  Same URLs as Docker — OrbStack exposes LoadBalancer services on localhost:"
	@echo "  App          $(APP)"
	@echo "  Ops Console  $(APP)/panel"
	@echo "  Grafana      http://localhost:3000   (same dashboard as Docker!)"
	@echo "  Prometheus   http://localhost:9090"
	@echo "  (cAdvisor runs in-cluster — see its data in the Grafana dashboard)"
	@echo ""
	@echo "  See the assigned addresses any time with:"
	@echo "    $(KCTL) -n $(K8S_NS) get svc"
	@echo ""

# --- Kubernetes teaching targets ---------------------------------------------
.PHONY: k8s-status
k8s-status: ## Show every object in the namespace, with a guided tour
	@echo "── Everything Kubernetes created for us ─────────────────────────────"
	@echo "In Docker you had CONTAINERS. Here you get higher-level objects that"
	@echo "MANAGE containers for you. Read the tour, then the output below."
	@echo ""
	@echo "  Deployment  desired state ('I want N copies of this'). Self-heals."
	@echo "  ReplicaSet  the Deployment's worker: keeps exactly N Pods alive."
	@echo "  Pod         the smallest unit — one or more containers, co-located."
	@echo "  Service     a stable name + virtual IP that load-balances to Pods."
	@echo "  DaemonSet   'one Pod on EVERY node' (used for cAdvisor/node-exporter)."
	@echo "  ConfigMap   config stored in the API (vs Compose bind-mounting files)."
	@echo "─────────────────────────────────────────────────────────────────────"
	$(KCTL) -n $(K8S_NS) get deployments,replicasets,pods,services,daemonsets,configmaps

.PHONY: k8s-pods
k8s-pods: ## Show pods with their node + IP (containers vs pods)
	@echo "A POD wraps your container(s) and gets its OWN cluster IP. Note the"
	@echo "RESTARTS column — Kubernetes restarts crashed containers for you, and"
	@echo "NODE shows which machine each pod landed on (the scheduler decided)."
	@echo ""
	$(KCTL) -n $(K8S_NS) get pods -o wide

.PHONY: k8s-services
k8s-services: ## Show services + endpoints (how pods find each other)
	@echo "A SERVICE is a stable front door: one name (e.g. 'prometheus') that"
	@echo "resolves via cluster DNS and load-balances across all matching Pods."
	@echo "In Compose, service names worked too — but there was no load balancing"
	@echo "and no health-aware routing. ENDPOINTS below are the live Pod IPs a"
	@echo "Service currently forwards to (they change as Pods come and go)."
	@echo ""
	$(KCTL) -n $(K8S_NS) get services
	@echo ""
	$(KCTL) -n $(K8S_NS) get endpoints

.PHONY: k8s-heal
k8s-heal: ## DEMO: delete the app pod and watch Kubernetes recreate it
	@echo "Compose would leave a killed container down (unless you restart it)."
	@echo "Kubernetes constantly reconciles desired vs actual state, so deleting"
	@echo "a Pod just makes it build a fresh one. Watch the AGE reset to 0s."
	@echo ""
	@echo "Before:"; $(KCTL) -n $(K8S_NS) get pods -l app=workshop-app
	@echo ""; echo "Deleting the app pod..."
	$(KCTL) -n $(K8S_NS) delete pod -l app=workshop-app
	@echo ""; echo "A few seconds later — a brand-new pod is already coming up:"
	$(KCTL) -n $(K8S_NS) get pods -l app=workshop-app

.PHONY: k8s-scale
k8s-scale: ## DEMO: scale the app to 3 replicas (and the statefulness catch)
	@echo "One command changes desired state; Kubernetes makes it so."
	$(KCTL) -n $(K8S_NS) scale deployment/app --replicas=3
	$(KCTL) -n $(K8S_NS) rollout status deployment/app --timeout=60s
	$(KCTL) -n $(K8S_NS) get pods -l app=workshop-app -o wide
	@echo ""
	@echo "⚠️  Teaching catch: our Ops Console keeps load state IN MEMORY, per pod."
	@echo "   With 3 pods the Service load-balances your clicks across them, so the"
	@echo "   numbers look inconsistent. That is the whole lesson about STATELESS"
	@echo "   design: Kubernetes assumes pods are interchangeable. Scale back with:"
	@echo "     $(KCTL) -n $(K8S_NS) scale deployment/app --replicas=1"

.PHONY: k8s-limits
k8s-limits: ## Show the app's resource requests/limits (vs unbounded Docker)
	@echo "Compose ran the app with NO resource caps. Here the Deployment declares"
	@echo "requests (what it's guaranteed) and limits (its hard ceiling):"
	@echo ""
	$(KCTL) -n $(K8S_NS) get pod -l app=workshop-app \
	  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{"  requests: "}{.spec.containers[0].resources.requests}{"\n"}{"  limits:   "}{.spec.containers[0].resources.limits}{"\n"}'
	@echo ""
	@echo "Try it: on the Ops Console, press 🧠 Allocate until you cross the memory"
	@echo "limit. Kubernetes OOM-kills the container and restarts it — watch with"
	@echo "'make k8s-pods' (the RESTARTS count climbs). CPU is throttled, not killed."

.PHONY: k8s-logs
k8s-logs: ## Tail the app pod's logs (kubectl logs vs docker logs)
	$(KCTL) -n $(K8S_NS) logs -f -l app=workshop-app --tail=50

.PHONY: k8s-explain
k8s-explain: ## Print a Docker-vs-Kubernetes cheat sheet
	@echo ""
	@echo "  ┌─────────────────────────────────────────────────────────────────────┐"
	@echo "  │  Docker Compose            │  Kubernetes                              │"
	@echo "  ├─────────────────────────────────────────────────────────────────────┤"
	@echo "  │  one host                  │  a cluster of nodes                      │"
	@echo "  │  container                 │  Pod (wraps 1+ containers)               │"
	@echo "  │  'docker run'              │  Deployment → ReplicaSet → Pod           │"
	@echo "  │  restart: unless-stopped   │  self-healing controllers (always on)    │"
	@echo "  │  scale: docker compose up  │  kubectl scale (declarative, instant)    │"
	@echo "  │    --scale (no LB)         │    with a Service load-balancing Pods    │"
	@echo "  │  service name on a network │  Service + cluster DNS + virtual IP      │"
	@echo "  │  ports: 8080:8080          │  Service type NodePort / LoadBalancer    │"
	@echo "  │  bind-mounted config files │  ConfigMaps / Secrets (API objects)      │"
	@echo "  │  a service per compose file│  DaemonSet = one Pod per node            │"
	@echo "  │  no resource caps          │  requests + limits (OOMKill / throttle)  │"
	@echo "  │  HEALTHCHECK in Dockerfile │  liveness + readiness probes             │"
	@echo "  │  docker ps / logs / stats  │  kubectl get / logs / top                │"
	@echo "  └─────────────────────────────────────────────────────────────────────┘"
	@echo ""
	@echo "  Same app, same dashboard, same URLs. Try: make k8s-heal, k8s-scale,"
	@echo "  k8s-limits, k8s-services — then compare with 'make docker-up'."
	@echo ""

##@ Shared helpers (work against whichever runtime is up on :8080)
.PHONY: run
run: ## Run the app locally with gunicorn (no Docker, no k8s)
	cd app && gunicorn --bind 0.0.0.0:8080 --workers 1 --threads 8 app:app

.PHONY: test
test: ## Run the unit tests exactly like CI does
	pip install -q -r app/requirements.txt -r tests/requirements-dev.txt
	pytest tests/ -v

.PHONY: stress-mem stress-cpu stress-disk stress-net stress-clean
stress-mem: ## Allocate 3 blocks of memory
	@for i in 1 2 3; do curl -s -XPOST $(APP)/api/load/memory/increase >/dev/null; done
	@echo "Allocated 3 memory blocks — watch the Memory panel."

stress-cpu: ## Start 2 CPU-burning workers
	@for i in 1 2; do curl -s -XPOST $(APP)/api/load/cpu/increase >/dev/null; done
	@echo "Started 2 CPU workers — watch the CPU panels."

stress-disk: ## Write 2 files to disk
	@for i in 1 2; do curl -s -XPOST $(APP)/api/load/disk/increase >/dev/null; done
	@echo "Wrote 2 files — watch the Disk panel."

stress-net: ## Start 2 network workers
	@for i in 1 2; do curl -s -XPOST $(APP)/api/load/network/increase >/dev/null; done
	@echo "Started 2 network workers — watch the Network throughput panel."

stress-clean: ## Delete the files written by stress-disk
	@curl -s -XPOST $(APP)/api/load/disk/cleanup >/dev/null
	@echo "Cleaned up disk files."
