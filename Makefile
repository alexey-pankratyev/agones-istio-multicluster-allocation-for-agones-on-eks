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
        status trace-eu trace-us kubeconfig-eu kubeconfig-us check-prereqs

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
