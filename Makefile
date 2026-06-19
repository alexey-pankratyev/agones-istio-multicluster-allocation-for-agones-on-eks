# ─────────────────────────────────────────────────────────────────────────────
# Variables — override any of these on the command line, e.g.:
#   make deploy AWS_ACCOUNT_ID=123456789012 NAMESPACE=demo
# ─────────────────────────────────────────────────────────────────────────────

NAMESPACE         ?= demo
ACCOUNT_PLACEHOLDER := 123456789012

# Auto-detect AWS account from current credentials when not set explicitly.
AWS_ACCOUNT_ID    ?= $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)

PACKAGES := packages/vpc packages/agones packages/istio packages/eks-cluster

# ─────────────────────────────────────────────────────────────────────────────
.DEFAULT_GOAL := help

.PHONY: help deploy install-packages create-namespace apply-claims \
        delete-claims delete-packages delete teardown \
        status trace-eu trace-us kubeconfig-eu kubeconfig-us check-prereqs \
        deploy-fleet alloc-local-eu alloc-local-us verify-mesh verify-allocation \
        alloc-cross-eu-to-us alloc-cross-us-to-eu test-pod-eu test-pod-us

help:
	@echo ""
	@echo "  Multi-Region Agones + Istio on EKS — Crossplane demo"
	@echo ""
	@echo "  Full deployment (one command):"
	@echo "    make deploy                     # install packages + apply claims"
	@echo ""
	@echo "  Step-by-step:"
	@echo "    make check-prereqs              # verify kubectl / crossplane / aws CLI"
	@echo "    make install-packages           # apply XRDs and Compositions"
	@echo "    make create-namespace           # kubectl create namespace $(NAMESPACE)"
	@echo "    make apply-claims               # apply cluster claims (substitutes account)"
	@echo ""
	@echo "  Observability:"
	@echo "    make status                     # show claim status"
	@echo "    make trace-eu                   # crossplane trace eu-west-1"
	@echo "    make trace-us                   # crossplane trace us-east-1"
	@echo "    make kubeconfig-eu              # write /tmp/eu-west-1.kubeconfig"
	@echo "    make kubeconfig-us              # write /tmp/us-east-1.kubeconfig"
	@echo ""
	@echo "  Testing:"
	@echo "    make deploy-fleet               # deploy demo Fleet on both clusters"
	@echo "    make verify-mesh                # check Istio remote cluster discovery + shared CA"
	@echo "    make alloc-local-eu             # allocate a GameServer locally on eu-west-1"
	@echo "    make alloc-local-us             # allocate a GameServer locally on us-east-1"
	@echo "    make verify-allocation          # deploy-fleet + local alloc on both clusters"
	@echo "    make test-pod-eu                # start a test pod with Istio sidecar on eu-west-1"
	@echo "    make test-pod-us                # start a test pod with Istio sidecar on us-east-1"
	@echo "    make alloc-cross-eu-to-us       # cross-cluster alloc: eu-west-1 pod → us-east-1 allocator"
	@echo "    make alloc-cross-us-to-eu       # cross-cluster alloc: us-east-1 pod → eu-west-1 allocator"
	@echo ""
	@echo "  Teardown:"
	@echo "    make delete-claims              # delete KubernetesCluster claims"
	@echo "    make delete-packages            # delete XRDs and Compositions"
	@echo "    make teardown                   # delete-claims + delete-packages"
	@echo ""
	@echo "  Variables (current values):"
	@echo "    AWS_ACCOUNT_ID = $(AWS_ACCOUNT_ID)"
	@echo "    NAMESPACE      = $(NAMESPACE)"
	@echo ""

# ─────────────────────────────────────────────────────────────────────────────
check-prereqs:
	@echo "==> Checking prerequisites..."
	@command -v kubectl      >/dev/null 2>&1 || (echo "ERROR: kubectl not found"      && exit 1)
	@command -v crossplane   >/dev/null 2>&1 || (echo "ERROR: crossplane CLI not found (https://docs.crossplane.io/latest/cli/)" && exit 1)
	@command -v aws          >/dev/null 2>&1 || (echo "ERROR: aws CLI not found"      && exit 1)
	@kubectl cluster-info    >/dev/null 2>&1 || (echo "ERROR: no active kubectl context" && exit 1)
	@kubectl get crd compositions.apiextensions.crossplane.io >/dev/null 2>&1 || \
		(echo "ERROR: Crossplane not installed in cluster (no Composition CRD)" && exit 1)
	@echo "    kubectl context : $$(kubectl config current-context)"
	@echo "    AWS account     : $(AWS_ACCOUNT_ID)"
	@[ -n "$(AWS_ACCOUNT_ID)" ] || (echo "ERROR: AWS_ACCOUNT_ID is empty — set it or run 'aws configure'" && exit 1)
	@echo "    OK"

# ─────────────────────────────────────────────────────────────────────────────
install-packages: check-prereqs
	@echo "==> Installing Crossplane packages (XRDs + Compositions)..."
	@for pkg in $(PACKAGES); do \
		echo "    applying $$pkg ..."; \
		kubectl apply -f $$pkg/definition.yaml -f $$pkg/aws.yaml; \
	done
	@echo "==> Waiting for XRDs to become Established..."
	@kubectl wait xrd \
		xvpcs.demo.crossplane.io \
		xagonesclusters.demo.crossplane.io \
		xistios.demo.crossplane.io \
		xkubernetesclusters.demo.crossplane.io \
		--for=condition=Established --timeout=60s
	@echo "    OK"

# ─────────────────────────────────────────────────────────────────────────────
create-namespace:
	@kubectl get namespace $(NAMESPACE) >/dev/null 2>&1 \
		|| (echo "==> Creating namespace $(NAMESPACE)..." && kubectl create namespace $(NAMESPACE))

# ─────────────────────────────────────────────────────────────────────────────
apply-claims: create-namespace
	@echo "==> Applying cluster claims (account: $(AWS_ACCOUNT_ID))..."
	@[ -n "$(AWS_ACCOUNT_ID)" ] || (echo "ERROR: AWS_ACCOUNT_ID is empty" && exit 1)
	@for f in examples/cluster-*.yaml; do \
		echo "    $$f"; \
		sed 's/$(ACCOUNT_PLACEHOLDER)/$(AWS_ACCOUNT_ID)/g' $$f | kubectl apply -f -; \
	done
	@echo ""
	@echo "==> Claims submitted. Watch progress:"
	@echo "    make status"
	@echo "    make trace-eu"
	@echo "    make trace-us"

# ─────────────────────────────────────────────────────────────────────────────
deploy: check-prereqs install-packages apply-claims
	@echo ""
	@echo "==> Deployment started."
	@echo "    EKS clusters take ~15 min to become fully ready."
	@echo "    Run 'make status' to track progress."

# ─────────────────────────────────────────────────────────────────────────────
status:
	@echo "==> Claim status:"
	@kubectl get kubernetescluster -n $(NAMESPACE) 2>/dev/null || echo "    (no claims found in namespace $(NAMESPACE))"
	@echo ""
	@echo "==> Composite resource status:"
	@kubectl get xkubernetescluster,xvpc,xagonescluster,xistio 2>/dev/null | grep -v "^$$" || true

trace-eu:
	@crossplane beta trace KubernetesCluster/gameserver-eu-west-1 -n $(NAMESPACE) 2>/dev/null \
		|| crossplane beta trace XKubernetesCluster \
			$$(kubectl get xkubernetescluster -o name 2>/dev/null | grep eu-west-1 | head -1 | cut -d/ -f2) 2>/dev/null \
		|| echo "No eu-west-1 cluster found"

trace-us:
	@crossplane beta trace KubernetesCluster/gameserver-us-east-1 -n $(NAMESPACE) 2>/dev/null \
		|| crossplane beta trace XKubernetesCluster \
			$$(kubectl get xkubernetescluster -o name 2>/dev/null | grep us-east-1 | head -1 | cut -d/ -f2) 2>/dev/null \
		|| echo "No us-east-1 cluster found"

kubeconfig-eu:
	@kubectl get secret gameserver-eu-west-1-kubeconfig -n crossplane-system \
		-o jsonpath='{.data.kubeconfig}' | base64 -d > /tmp/eu-west-1.kubeconfig
	@echo "Kubeconfig written to /tmp/eu-west-1.kubeconfig"
	@echo "  KUBECONFIG=/tmp/eu-west-1.kubeconfig kubectl get nodes"

kubeconfig-us:
	@kubectl get secret gameserver-us-east-1-kubeconfig -n crossplane-system \
		-o jsonpath='{.data.kubeconfig}' | base64 -d > /tmp/us-east-1.kubeconfig
	@echo "Kubeconfig written to /tmp/us-east-1.kubeconfig"
	@echo "  KUBECONFIG=/tmp/us-east-1.kubeconfig kubectl get nodes"

# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
deploy-fleet: kubeconfig-eu kubeconfig-us
	@echo "==> Deploying demo Fleet on eu-west-1..."
	@kubectl apply --kubeconfig=/tmp/eu-west-1.kubeconfig -f examples/fleet.yaml
	@echo "==> Deploying demo Fleet on us-east-1..."
	@kubectl apply --kubeconfig=/tmp/us-east-1.kubeconfig -f examples/fleet.yaml
	@echo ""
	@echo "    Waiting for GameServers to become Ready (~30s)..."
	@sleep 30
	@echo ""
	@echo "==> eu-west-1 GameServers:"
	@kubectl get gameserver -n agones-gameservers --kubeconfig=/tmp/eu-west-1.kubeconfig 2>/dev/null
	@echo ""
	@echo "==> us-east-1 GameServers:"
	@kubectl get gameserver -n agones-gameservers --kubeconfig=/tmp/us-east-1.kubeconfig 2>/dev/null

# ─────────────────────────────────────────────────────────────────────────────
alloc-local-eu: kubeconfig-eu
	@echo "==> Allocating a GameServer on eu-west-1..."
	@kubectl create --kubeconfig=/tmp/eu-west-1.kubeconfig -f examples/allocation-local.yaml
	@echo ""
	@kubectl get gameserver -n agones-gameservers --kubeconfig=/tmp/eu-west-1.kubeconfig

alloc-local-us: kubeconfig-us
	@echo "==> Allocating a GameServer on us-east-1..."
	@kubectl create --kubeconfig=/tmp/us-east-1.kubeconfig -f examples/allocation-local.yaml
	@echo ""
	@kubectl get gameserver -n agones-gameservers --kubeconfig=/tmp/us-east-1.kubeconfig

# ─────────────────────────────────────────────────────────────────────────────
verify-mesh: kubeconfig-eu kubeconfig-us
	@echo "==> Remote cluster discovery (eu-west-1 sees us-east-1):"
	@istioctl remote-clusters --kubeconfig=/tmp/eu-west-1.kubeconfig 2>/dev/null || \
		echo "    istioctl not found — install from https://istio.io/latest/docs/setup/getting-started/"
	@echo ""
	@echo "==> Remote cluster discovery (us-east-1 sees eu-west-1):"
	@istioctl remote-clusters --kubeconfig=/tmp/us-east-1.kubeconfig 2>/dev/null || true
	@echo ""
	@echo "==> Shared root CA fingerprint — both lines must match:"
	@echo -n "    eu-west-1: " && \
		kubectl get secret cacerts -n istio-system --kubeconfig=/tmp/eu-west-1.kubeconfig \
		-o jsonpath='{.data.root-cert\.pem}' 2>/dev/null | base64 -d | openssl x509 -noout -fingerprint 2>/dev/null \
		|| echo "(cacerts not found)"
	@echo -n "    us-east-1: " && \
		kubectl get secret cacerts -n istio-system --kubeconfig=/tmp/us-east-1.kubeconfig \
		-o jsonpath='{.data.root-cert\.pem}' 2>/dev/null | base64 -d | openssl x509 -noout -fingerprint 2>/dev/null \
		|| echo "(cacerts not found)"
	@echo ""
	@echo "==> East-west gateway NLB addresses:"
	@echo -n "    eu-west-1: " && \
		kubectl get svc gameserver-eu-west-1-istio-eastwestgateway -n istio-system \
		--kubeconfig=/tmp/eu-west-1.kubeconfig \
		-o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "(pending)"
	@echo ""
	@echo -n "    us-east-1: " && \
		kubectl get svc gameserver-us-east-1-istio-eastwestgateway -n istio-system \
		--kubeconfig=/tmp/us-east-1.kubeconfig \
		-o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "(pending)"
	@echo ""

# ─────────────────────────────────────────────────────────────────────────────
verify-allocation: deploy-fleet alloc-local-eu alloc-local-us
	@echo ""
	@echo "==> Final GameServer state on eu-west-1 (one should be Allocated):"
	@kubectl get gameserver -n agones-gameservers --kubeconfig=/tmp/eu-west-1.kubeconfig 2>/dev/null
	@echo ""
	@echo "==> Final GameServer state on us-east-1 (one should be Allocated):"
	@kubectl get gameserver -n agones-gameservers --kubeconfig=/tmp/us-east-1.kubeconfig 2>/dev/null

# ─────────────────────────────────────────────────────────────────────────────
# Cross-cluster allocation test — runs inside a pod WITH Istio sidecar.
#
# The pod lives in agones-system (Istio injection enabled). Envoy intercepts
# the outbound call to agones-allocator:443 and, based on the mesh-region
# header, routes it through the east-west gateway to the remote cluster.
# The allocator responds with a GameServer from that cluster.
#
# Prerequisites: make deploy-fleet must have been run first.
# ─────────────────────────────────────────────────────────────────────────────
test-pod-eu: kubeconfig-eu
	@echo "==> Starting test pod on eu-west-1 (agones-system, Istio sidecar injected)..."
	@kubectl --kubeconfig=/tmp/eu-west-1.kubeconfig delete pod allocator-test \
		-n agones-system --ignore-not-found 2>/dev/null; true
	@kubectl --kubeconfig=/tmp/eu-west-1.kubeconfig apply -f examples/test-pod.yaml
	@echo "    Waiting for pod to be ready (~20s for sidecar injection)..."
	@kubectl --kubeconfig=/tmp/eu-west-1.kubeconfig wait pod allocator-test \
		-n agones-system --for=condition=Ready --timeout=60s
	@kubectl --kubeconfig=/tmp/eu-west-1.kubeconfig get pod allocator-test -n agones-system

test-pod-us: kubeconfig-us
	@echo "==> Starting test pod on us-east-1 (agones-system, Istio sidecar injected)..."
	@kubectl --kubeconfig=/tmp/us-east-1.kubeconfig delete pod allocator-test \
		-n agones-system --ignore-not-found 2>/dev/null; true
	@kubectl --kubeconfig=/tmp/us-east-1.kubeconfig apply -f examples/test-pod.yaml
	@echo "    Waiting for pod to be ready (~20s for sidecar injection)..."
	@kubectl --kubeconfig=/tmp/us-east-1.kubeconfig wait pod allocator-test \
		-n agones-system --for=condition=Ready --timeout=60s
	@kubectl --kubeconfig=/tmp/us-east-1.kubeconfig get pod allocator-test -n agones-system

# ─────────────────────────────────────────────────────────────────────────────
ALLOC_PAYLOAD := {"namespace":"agones-gameservers","gameServerSelectors":[{"matchLabels":{"agones.dev/fleet":"demo-gameserver"}}]}

alloc-cross-eu-to-us: kubeconfig-eu
	@echo "==> Cross-cluster allocation: eu-west-1 pod → us-east-1 allocator"
	@echo "    Istio routes the request via east-west gateway based on mesh-region header."
	@echo ""
	@kubectl --kubeconfig=/tmp/eu-west-1.kubeconfig exec -n agones-system allocator-test -- \
		curl -s --max-time 15 \
		-X POST \
		http://agones-allocator.agones-system.svc.cluster.local:443/gameserverallocation \
		-H "mesh-region: us-east-1" \
		-H "Content-Type: application/json" \
		-d '$(ALLOC_PAYLOAD)' | python3 -m json.tool 2>/dev/null || \
		kubectl --kubeconfig=/tmp/eu-west-1.kubeconfig exec -n agones-system allocator-test -- \
		curl -s --max-time 15 \
		-X POST \
		http://agones-allocator.agones-system.svc.cluster.local:443/gameserverallocation \
		-H "mesh-region: us-east-1" \
		-H "Content-Type: application/json" \
		-d '$(ALLOC_PAYLOAD)'
	@echo ""
	@echo "==> us-east-1 GameServers (one should now be Allocated):"
	@kubectl get gameserver -n agones-gameservers --kubeconfig=/tmp/us-east-1.kubeconfig 2>/dev/null

alloc-cross-us-to-eu: kubeconfig-us
	@echo "==> Cross-cluster allocation: us-east-1 pod → eu-west-1 allocator"
	@echo "    Istio routes the request via east-west gateway based on mesh-region header."
	@echo ""
	@kubectl --kubeconfig=/tmp/us-east-1.kubeconfig exec -n agones-system allocator-test -- \
		curl -s --max-time 15 \
		-X POST \
		http://agones-allocator.agones-system.svc.cluster.local:443/gameserverallocation \
		-H "mesh-region: eu-west-1" \
		-H "Content-Type: application/json" \
		-d '$(ALLOC_PAYLOAD)' | python3 -m json.tool 2>/dev/null || \
		kubectl --kubeconfig=/tmp/us-east-1.kubeconfig exec -n agones-system allocator-test -- \
		curl -s --max-time 15 \
		-X POST \
		http://agones-allocator.agones-system.svc.cluster.local:443/gameserverallocation \
		-H "mesh-region: eu-west-1" \
		-H "Content-Type: application/json" \
		-d '$(ALLOC_PAYLOAD)'
	@echo ""
	@echo "==> eu-west-1 GameServers (one should now be Allocated):"
	@kubectl get gameserver -n agones-gameservers --kubeconfig=/tmp/eu-west-1.kubeconfig 2>/dev/null

# ─────────────────────────────────────────────────────────────────────────────
delete-claims:
	@echo "==> Deleting claims..."
	@kubectl delete kubernetescluster -n $(NAMESPACE) --all 2>/dev/null || true
	@echo "    Waiting for managed resources to be deleted..."
	@echo "    (this can take several minutes as EKS clusters are deprovisioned)"

delete-packages:
	@echo "==> Deleting Crossplane packages..."
	@for pkg in $(PACKAGES); do \
		kubectl delete -f $$pkg/aws.yaml -f $$pkg/definition.yaml --ignore-not-found 2>/dev/null || true; \
	done

teardown: delete-claims delete-packages
	@echo "==> Teardown complete."
