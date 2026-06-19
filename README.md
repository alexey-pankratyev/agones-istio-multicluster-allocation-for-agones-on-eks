# Multi-Region Game Server Allocation on EKS with Agones and Istio

> This project deploys a multi-region game server infrastructure on Amazon EKS using Crossplane - a single claim per region provisions the full stack: VPC with public and private subnets, EKS, Agones allocator, Karpenter SPOT node pools, and an Istio multi-primary mesh - with OIDC/IRSA roles derived automatically from cluster status; two clusters form one Istio mesh with a shared mTLS root CA and east-west gateways for cross-cluster traffic; the matchmaker calls a single local gRPC endpoint - Istio routes allocation requests by `mesh-region` header and retries across regions on failure, no per-region endpoint logic required in application code.

---

## The Problem

You run game servers on AWS. Players are in North America and Europe. You want the nearest cluster to handle allocation, but fall back to the other region when one is saturated. Your matchmaker should not care about cluster topology.

The standard approach - one NLB per cluster, custom endpoint logic in the matchmaker, per cluster certificate management - becomes an operational burden at scale.

The solution here: Agones multi-cluster allocation routed by an Istio service mesh. The matchmaker sets a `mesh-region` header. Istio routes it to the right regional allocator. `retryRemoteLocalities: true` handles cross-region failover automatically.

---

## Repository Structure

```
.
├── README.md
├── packages/
│   ├── vpc/                  # VPC, subnets, IGW, NAT GWs, route tables
│   │   ├── definition.yaml   # XRD: VPC API
│   │   ├── aws.yaml          # Composition: full network stack per cluster
│   │   └── crossplane.yaml
│   ├── eks-cluster/          # EKS + IAM + addons + Karpenter + cert-manager
│   │   ├── definition.yaml   # XRD: KubernetesCluster API
│   │   ├── aws.yaml          # Composition: vpc → eks-cluster → agones → istio
│   │   └── crossplane.yaml
│   ├── agones/               # Agones allocator + Karpenter game server pools
│   │   ├── definition.yaml   # XRD: AgonesCluster API
│   │   ├── aws.yaml          # Composition: Agones Helm + NodePools + IRSA role
│   │   └── crossplane.yaml
│   └── istio/                # istiod + east-west gateway + mesh routing
│       ├── definition.yaml   # XRD: Istio API
│       ├── aws.yaml          # Composition: Istio Helm + VirtualService + DestinationRule
│       └── crossplane.yaml
└── examples/
    ├── cluster-us-east-1.yaml   # Full claim: EKS + Agones + Istio in us-east-1
    └── cluster-eu-west-1.yaml   # Full claim: EKS + Agones + Istio in eu-west-1
```

**One claim per cluster.** The `eks-cluster` Composition first creates a `XVPC` nested XR (networking), then calls the `agones` and `istio` packages as further nested composite resources - you do not apply separate VPC, Agones, or Istio claims.

---

## Architecture

### Networking: Auto-Provisioned VPC per Cluster

Each cluster gets its own VPC created automatically by the `vpc` package. No pre-existing subnets or VPC IDs are required in the claim - just specify a CIDR block and the availability zones.

```
vpc.cidr: 10.100.0.0/16  (eu-west-1)     vpc.cidr: 10.110.0.0/16  (us-east-1)
availabilityZones:                        availabilityZones:
  - eu-west-1a                              - us-east-1a
  - eu-west-1b                              - us-east-1b

Per AZ layout (eu-west-1, /16 base = 10.100):
  AZ 0 (eu-west-1a):  private 10.100.0.0/24   public 10.100.100.0/24
  AZ 1 (eu-west-1b):  private 10.100.1.0/24   public 10.100.101.0/24

Resources created per AZ:
  • Private subnet  - tagged karpenter.sh/subnetzone=<az>         (Agones system nodes)
  • Public subnet   - tagged karpenter.sh/subnetzone=<az>-public  (game server nodes)
  • Elastic IP + NAT Gateway in the public subnet
  • Private route table routing 0.0.0.0/0 → NAT GW
Public route table (shared) routing 0.0.0.0/0 → Internet Gateway
```

The Karpenter `EC2NodeClass` subnet selectors default to the first AZ's tags (`<region>a` and `<region>a-public`) when not overridden in the claim.

To use an existing VPC instead, set `vpcId`, `subnetIds`, `subnetPrivateIds`, and `subnetPublicIds` explicitly in the claim - the XVPC step is skipped in that case.

### Istio Multi-Primary on Different Networks

This setup follows the [Istio multi-primary on different networks](https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/) model. Each cluster runs its own istiod control plane (multi-primary), and the clusters are on separate VPC networks (different networks). Cross-cluster traffic flows through the east-west gateway on port 15443.

```
  Management Cluster (Crossplane)
  ┌────────────────────────────────────────────────────┐
  │  Namespace: demo                                   │
  │  ┌──────────────────────┐ ┌──────────────────────┐ │
  │  │ KubernetesCluster    │ │ KubernetesCluster    │ │
  │  │ gameserver-us-east-1 │ │ gameserver-eu-west-1 │ │
  │  └─────────┬────────────┘ └──────────┬───────────┘ │
  │            │ reconciles              │ reconciles  │
  │ ┌──────────▼─────────────────────────▼───────────┐ │
  │ │  Crossplane Compositions (eks-cluster package) │ │
  │ │  → creates XVPC + XAgonesCluster + XIstio XRs  │ │
  │ └────────────────────────────────────────────────┘ │
  │                                                    │
  │  cert-manager namespace                            │
  │  Secret: istio-ca  ◄── created by primary cluster  │
  │  (shared root CA for all clusters in the mesh)     │
  └────────────────────────────────────────────────────┘
            │                          │
            │ AWS API                  │ AWS API
            ▼                          ▼
  ┌─────────────────────┐    ┌─────────────────────────┐
  │  EKS: us-east-1     │    │  EKS: eu-west-1         │
  │  VPC: 10.110.0.0/16 │    │  VPC: 10.100.0.0/16     │
  │                     │    │                         │
  │  ┌───────────────┐  │    │  ┌───────────────────┐  │
  │  │ istiod        │  │    │  │ istiod            │  │
  │  │ (multi-       │  │    │  │ (multi-primary,   │  │
  │  │  primary)     │  │    │  │  independent CP)  │  │
  │  └───────────────┘  │    │  └───────────────────┘  │
  │                     │    │                         │
  │  ┌───────────────┐  │    │  ┌───────────────────┐  │
  │  │ east-west     │◄─┼────┼─►│ east-west         │  │
  │  │ gateway       │  │    │  │ gateway           │  │
  │  │ NLB:15443     │  │    │  │ NLB:15443         │  │
  │  └───────────────┘  │    │  └───────────────────┘  │
  │  Network:           │    │  Network:               │
  │  us-east-1-istio-   │    │  eu-west-1-istio-       │
  │  network            │    │  network                │
  └─────────────────────┘    └─────────────────────────┘
```

**Multi-primary** means each istiod is independent - there is no single point of failure in the control plane. If us-east-1 istiod goes down, the eu-west-1 data plane continues to work.

**Different networks** means the two VPCs are not peered or connected at the L3 level. All cross-cluster pod-to-pod traffic is tunnelled through the east-west gateway on port 15443 using SNI-based AUTO_PASSTHROUGH.

### Remote Secret Exchange (Service Discovery)

For istiod in each cluster to discover services in the other cluster, it needs read access to the remote Kubernetes API. Crossplane automates this:

```
Management cluster
┌───────────────────────────────────────────────────────────┐
│                                                           │
│  Namespace: gameserver-us-east-1                          │
│  Secret: istio-remote-secret-gameserver-us-east-1         │
│  (written by us-east-1 Istio package)                     │
│                        │                                  │
│                        │  Crossplane copies via reference │
│                        ▼                                  │
│  Namespace: gameserver-eu-west-1                          │
│  Secret: istio-remote-secret-gameserver-us-east-1         │
│  (consumed by eu-west-1 istio package → placed on         │
│   eu-west-1 cluster in namespace istio-system)            │
│                                                           │
│  (same pattern in reverse for eu-west-1 → us-east-1)      │
└───────────────────────────────────────────────────────────┘
```

### Shared Root CA

Cross-cluster mTLS requires a shared trust root. All clusters must use the same root CA so workload certificates are mutually trusted.

```
Management cluster cert-manager
┌────────────────────────────────────────────────────────┐
│                                                        │
│  ClusterIssuer: istio-root-ca-selfsigned               │
│         │                                              │
│         │ issues                                       │
│         ▼                                              │
│  Certificate: istio-ca  →  Secret: istio-ca            │
│  (isCA: true, ECDSA P-256, 10yr validity)              │
│         │                                              │
│         │  Crossplane references (data copy)           │
│         ├──────────────────────────────────────────┐   │
│         ▼                                          ▼   │
│  us-east-1 cluster             eu-west-1 cluster       │
│  Secret: cacerts               Secret: cacerts         │
│  (istio-system)                (istio-system)          │
│                                                        │
│  istiod signs workload certs from this shared root     │
│  → mutual trust across clusters without config         │
└────────────────────────────────────────────────────────┘
```

Exactly **one cluster** should have `istio.primary: true`. That cluster's Composition creates the `istio-ca` Certificate and ClusterIssuer on the management cluster. All other clusters set `primary: false` and receive the CA via Crossplane namespace references.

### OIDC / IRSA - Auto-Derived

The `agones` package creates an IAM Role for the `agones-sdk` ServiceAccount (IRSA) so game server pods can call AWS APIs (e.g. S3 for replays). The OIDC issuer URL for this trust policy is **read automatically** from `status.atProvider.identity[0].oidc[0].issuer` of the EKS cluster - you do not need to specify it in the claim.

The flow across reconcile cycles:
1. **Cycle 1** - EKS cluster is created; OIDC issuer appears in its status.
2. **Cycle 2** - `eks-cluster` composition reads the issuer URL, strips `https://`, and passes it as `oidc` to the `XAgonesCluster` nested XR.
3. **Cycle 2** - `agones` composition creates the `<id>-role-agones-sdk` IAM Role with the correct OIDC federated trust policy.

The `oidc` field still exists in the `agones` XRD as an optional override for cases where an existing role or a specific issuer URL must be used.

### Agones Multi-Cluster Allocation Flow

The matchmaker pod runs **inside one of the clusters** (e.g. us-east-1). It calls the local agones-allocator service. Istio intercepts the call on the sidecar and, based on the `mesh-region` header, routes it to the appropriate regional allocator - either locally or across clusters via the east-west gateway.

```
  us-east-1 cluster
  ┌────────────────────────────────────────────────────────────────┐
  │                                                                │
  │  ┌──────────────────┐                                          │
  │  │  Matchmaker pod  │                                          │
  │  │  (agones-        │                                          │
  │  │   gameservers ns)│                                          │
  │  └────────┬─────────┘                                          │
  │           │  gRPC call to:                                     │
  │           │  agones-allocator.agones-system.svc.cluster.local  │
  │           │  Header: mesh-region: eu-west-1                    │
  │           │                                                    │
  │           ▼  (Istio sidecar intercepts)                        │
  │  ┌────────────────────────────────────────┐                    │
  │  │  Envoy (matchmaker sidecar)             │                   │
  │  │  Looks up VirtualService rule:          │                   │
  │  │    mesh-region: eu-west-1               │                   │
  │  │    → subset eu-west-1                   │                   │
  │  │    → host agones-allocator...           │                   │
  │  │      routed via east-west GW endpoint   │                   │
  │  └────────────────┬───────────────────────┘                    │
  │                   │  mTLS (ISTIO_MUTUAL)                       │
  │                   ▼                                            │
  │  ┌────────────────────────────────────────┐                    │
  │  │  East-west gateway (us-east-1)          │                   │
  │  │  NLB port 15443                         │                   │
  │  │  SNI: agones-allocator.agones-system    │                   │
  │  │       .svc.cluster.local                │                   │
  │  │  AUTO_PASSTHROUGH - TLS not terminated  │                   │
  │  └────────────────┬───────────────────────┘                    │
  └───────────────────┼────────────────────────────────────────────┘
                      │  NLB → NLB  (cross-region: TGW or internet)
                      ▼
  eu-west-1 cluster
  ┌────────────────────────────────────────────────────────────────┐
  │                   │                                            │
  │  ┌────────────────▼───────────────────────┐                    │
  │  │  East-west gateway (eu-west-1)         │                    │
  │  │  Matches SNI → routes to local service │                    │
  │  └────────────────┬───────────────────────┘                    │
  │                   │                                            │
  │                   ▼                                            │
  │  ┌────────────────────────────────────────┐                    │
  │  │  agones-allocator pod (eu-west-1)      │                    │
  │  │  Finds a Ready GameServer              │                    │
  │  │  Returns: NodeIP, port, credentials    │                    │
  │  └────────────────────────────────────────┘                    │
  │                                                                │
  │  ┌────────────────────────────────────────┐                    │
  │  │  Karpenter game server nodes (SPOT)    │                    │
  │  │  Fleet: 5 × Ready GameServer pods      │                    │
  │  └────────────────────────────────────────┘                    │
  └────────────────────────────────────────────────────────────────┘
```

**Same topology exists on eu-west-1** - it also has a matchmaker, local agones-allocator, and Istio mesh. A matchmaker on eu-west-1 can in exactly the same way route allocations to us-east-1 by setting `mesh-region: us-east-1`.

The `retryRemoteLocalities: true` policy means if the target regional allocator returns a retryable error (no Ready servers, connection refused), Envoy retries against other subsets automatically - no matchmaker logic required.

---

## Default Versions

| Component | Default |
|---|---|
| Kubernetes (EKS) | 1.35 |
| Karpenter | 1.13.0 |
| Agones | 1.55.0 |
| CoreDNS addon | v1.13.1-eksbuild.1 |
| kube-proxy addon | v1.35.0-eksbuild.2 |
| vpc-cni addon | v1.21.1-eksbuild.1 |
| aws-ebs-csi-driver addon | v1.56.0-eksbuild.1 |
| cert-manager | v1.17.2 |

All defaults can be overridden in the claim.

---

## Deployment

### Prerequisites

You need an existing EKS cluster to act as the management cluster (the cluster where Crossplane runs and reconciles everything). The two game server clusters are created by Crossplane automatically — you don't provision them manually.

**Tools on your workstation:**

| Tool | Purpose |
|---|---|
| `kubectl` | interacts with management and workload clusters |
| `aws` CLI | auto-detects account ID, configures IRSA |
| `crossplane` CLI | `crossplane beta trace` for debugging |

**What must be installed on the management cluster:**

| Component | Purpose |
|---|---|
| Crossplane ≥ 2.1.4 | Composition engine |
| `provider-aws` (upbound) | EKS, IAM, EC2, VPC resources |
| `provider-kubernetes` | Kubernetes Object resources on workload clusters |
| `provider-helm` | Helm Release resources on workload clusters |
| `function-go-templating` | Go template Composition function |
| `function-auto-ready` | Readiness detection function |

#### Installing Crossplane on the management cluster

```bash
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace \
  --version 2.1.4

# Install providers and functions
kubectl apply -f - <<EOF
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: upbound-provider-family-aws
spec:
  package: xpkg.upbound.io/upbound/provider-family-aws:v1.19.0
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: upbound-provider-aws-eks
spec:
  package: xpkg.upbound.io/upbound/provider-aws-eks:v1.19.0
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: upbound-provider-aws-ec2
spec:
  package: xpkg.upbound.io/upbound/provider-aws-ec2:v1.19.0
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: upbound-provider-aws-iam
spec:
  package: xpkg.upbound.io/upbound/provider-aws-iam:v1.19.0
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: crossplane-contrib-provider-kubernetes
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v1.2.0
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: crossplane-contrib-provider-helm
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-helm:v1.1.0
---
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-go-templating
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-go-templating:v0.11.3
---
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-auto-ready
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-auto-ready:v0.6.0
EOF
```

#### Configuring AWS access for provider-aws

`provider-aws` needs IAM permissions to create EKS clusters, VPCs, IAM roles, and more. The recommended approach is **IRSA** (IAM Roles for Service Accounts) — no static credentials stored in the cluster.

```bash
# 1. Create an IAM role with AdministratorAccess (or a scoped policy)
#    and trust the management cluster's OIDC provider.
#    Replace the values with your management cluster details.
MGMT_CLUSTER=my-management-cluster
REGION=eu-west-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC=$(aws eks describe-cluster --name $MGMT_CLUSTER --region $REGION \
  --query 'cluster.identity.oidc.issuer' --output text | sed 's|https://||')

aws iam create-role --role-name crossplane-provider-aws \
  --assume-role-policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": {\"Federated\": \"arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC}\"},
      \"Action\": \"sts:AssumeRoleWithWebIdentity\",
      \"Condition\": {\"StringLike\": {
        \"${OIDC}:sub\": \"system:serviceaccount:crossplane-system:provider-aws-*\"
      }}
    }]
  }"

aws iam attach-role-policy --role-name crossplane-provider-aws \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

# 2. Point the ProviderConfig at the role
kubectl apply -f - <<EOF
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: IRSA
EOF
```

For `provider-kubernetes` and `provider-helm`, a `ProviderConfig` with `source: InjectedIdentity` is sufficient — they use the management cluster's own service account:

```bash
kubectl apply -f - <<EOF
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: InjectedIdentity
---
apiVersion: helm.crossplane.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: InjectedIdentity
EOF
```

A `Makefile` is included to run all deployment steps without memorising commands. Run `make` or `make help` to see all available targets.

### Quick start — one command

```bash
make deploy
```

AWS account ID is auto-detected from your current credentials via `aws sts get-caller-identity`. To override:

```bash
make deploy AWS_ACCOUNT_ID=123456789012
```

This single target runs `check-prereqs → install-packages → create-namespace → apply-claims` in sequence. EKS clusters take ~15 minutes to become fully ready.

### Step by step

If you prefer to run each phase individually:

```bash
# Verify kubectl context, crossplane CLI, aws CLI, and that Crossplane is installed
make check-prereqs

# Apply XRDs and Compositions to the management cluster
make install-packages

# Create the demo namespace and submit both cluster claims
make apply-claims
```

The `apply-claims` target substitutes the placeholder account number in `examples/cluster-*.yaml` at apply time using `sed` — the example files themselves are never modified and safe to commit.

### Tracking progress

```bash
make status       # claim SYNCED/READY + all composite resource status
make trace-eu     # full crossplane resource tree for gameserver-eu-west-1
make trace-us     # full crossplane resource tree for gameserver-us-east-1
```

### What gets provisioned

Both claims are submitted together and reconcile in parallel. Each one creates:

1. **VPC** — `10.110.0.0/16` (us-east-1) and `10.100.0.0/16` (eu-west-1), public + private subnets across 2 AZs, IGW, NAT GWs, route tables
2. **EKS 1.35** — control plane wired to the new subnets, system NodeGroup with `CriticalAddonsOnly` taint
3. **Karpenter 1.13.0** — IRSA role and OIDC provider auto-created once EKS reports its issuer URL
4. **EKS addons** — CoreDNS, kube-proxy, VPC CNI, EBS CSI driver
5. **cert-manager v1.17.2** — webhook certs for Agones; shared Istio root CA on the primary cluster
6. **Agones 1.55.0** — allocator, controller, extensions with Istio sidecar; Karpenter NodePools for game server and system nodes
7. **Istio 1.26.2** — istiod (multi-primary), east-west gateway NLB, shared mTLS root CA, cross-cluster remote secrets

The us-east-1 claim has `istio.primary: true` — it creates the shared Istio root CA in cert-manager on the management cluster. The eu-west-1 claim receives that CA automatically via Crossplane namespace references.

### Getting kubeconfigs

```bash
make kubeconfig-eu    # writes /tmp/eu-west-1.kubeconfig
make kubeconfig-us    # writes /tmp/us-east-1.kubeconfig
```

After that, use them with any `kubectl` or `istioctl` command:

```bash
KUBECONFIG=/tmp/eu-west-1.kubeconfig kubectl get nodes
KUBECONFIG=/tmp/us-east-1.kubeconfig kubectl get pods -n agones-system
```

### Verify the Istio mesh

```bash
# Check remote cluster discovery from us-east-1
istioctl remote-clusters --kubeconfig=/tmp/us-east-1.kubeconfig
# NAME                      SECRET                                    STATUS    ISTIOD
# gameserver-eu-west-1      istio-remote-secret-gameserver-eu-west-1  synced    istiod-xxx

# Verify east-west gateways received NLB addresses
kubectl get svc -n istio-system --kubeconfig=/tmp/us-east-1.kubeconfig \
  gameserver-us-east-1-istio-eastwestgateway

# Verify both clusters share the same root CA — fingerprints must match
kubectl get secret cacerts -n istio-system --kubeconfig=/tmp/us-east-1.kubeconfig \
  -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -noout -fingerprint

kubectl get secret cacerts -n istio-system --kubeconfig=/tmp/eu-west-1.kubeconfig \
  -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -noout -fingerprint
```

### Test allocation

The `examples/` directory contains ready-to-use manifests for testing:

| File | Purpose |
|---|---|
| `examples/fleet.yaml` | 3-replica Fleet of `simple-game-server` pods |
| `examples/allocation-local.yaml` | `GameServerAllocation` that picks a Ready server from the local cluster |
| `examples/test-pod.yaml` | `nicolaka/netshoot` pod with Istio sidecar — used for cross-cluster allocation tests |

#### Local allocation

Deploy the Fleet and verify both clusters allocate locally:

```bash
make deploy-fleet          # deploy Fleet on both clusters, wait for Ready
make alloc-local-eu        # allocate one GameServer on eu-west-1
make alloc-local-us        # allocate one GameServer on us-east-1
```

Or all at once:

```bash
make verify-allocation     # deploy-fleet + alloc-local-eu + alloc-local-us
```

Expected output — one GameServer transitions from `Ready` to `Allocated`:

```
NAME                          STATE       ADDRESS                                      PORT
demo-gameserver-xxxxx-aaaaa   Allocated   ec2-1-2-3-4.eu-west-1.compute.amazonaws.com  7833
demo-gameserver-xxxxx-bbbbb   Ready       ec2-1-2-3-4.eu-west-1.compute.amazonaws.com  7585
demo-gameserver-xxxxx-ccccc   Ready       ec2-1-2-3-4.eu-west-1.compute.amazonaws.com  7270
```

#### Cross-cluster allocation via Istio mesh

This is the main scenario — a pod on eu-west-1 allocates a GameServer **on us-east-1** by setting the `mesh-region` header. Envoy intercepts the outbound call to `agones-allocator:443`, matches the header in the VirtualService, and routes it through the east-west gateway NLB to the remote cluster's allocator.

```
eu-west-1 pod
  └─ curl http://agones-allocator:443/gameserverallocation  (Header: mesh-region: us-east-1)
       └─ Envoy sidecar (eu-west-1)  →  mTLS  →  east-west gateway NLB (us-east-1):15443
                                                      └─ AUTO_PASSTHROUGH (SNI routing)
                                                           └─ agones-allocator pod (us-east-1)
                                                                └─ {"gameServerName": "...", "address": "ec2-44-...compute-1.amazonaws.com"}
```

**Prerequisites:** the test pod must run inside the `agones-system` namespace (where Istio injection is enabled) so it gets an Envoy sidecar that knows the VirtualService rules.

```bash
# Start the test pod with Istio sidecar on eu-west-1
make test-pod-eu

# Allocate from eu-west-1 — routed to us-east-1 via east-west gateway
make alloc-cross-eu-to-us
```

Expected output — the returned `address` is a us-east-1 EC2 hostname:

```json
{
  "gameServerName": "demo-gameserver-xxxxx-yyyyy",
  "ports": [{"name": "default", "port": 7114}],
  "address": "ec2-44-211-153-196.compute-1.amazonaws.com",
  "source": "local"
}
```

And on us-east-1 you can confirm the GameServer is now `Allocated`:

```bash
KUBECONFIG=/tmp/us-east-1.kubeconfig kubectl get gameserver -n agones-gameservers
```

The reverse direction works identically:

```bash
make test-pod-us           # start test pod on us-east-1
make alloc-cross-us-to-eu  # allocate from us-east-1 → eu-west-1
```

**Manual curl** — if you want to run the request by hand, exec into the test pod and fire the call directly:

```bash
# Start the test pod first
make test-pod-eu

# Then exec in and run curl yourself
kubectl --kubeconfig=/tmp/eu-west-1.kubeconfig exec -n agones-system allocator-test -- \
  curl -s -X POST \
  http://agones-allocator.agones-system.svc.cluster.local:443/gameserverallocation \
  -H "mesh-region: us-east-1" \
  -H "Content-Type: application/json" \
  -d '{"namespace":"agones-gameservers","gameServerSelectors":[{"matchLabels":{"agones.dev/fleet":"demo-gameserver"}}]}' \
  | python3 -m json.tool
```

Change `mesh-region: us-east-1` to `mesh-region: eu-west-1` to allocate locally instead.

#### Resetting GameServers between test runs

After each allocation the GameServer stays in `Allocated` state until you delete it. When all servers are allocated, the next request returns `there is no available GameServer to allocate`. To reset:

```bash
make reset-fleet
```

This force-deletes all `Allocated` GameServers on both clusters (`--force --grace-period=0`) and re-applies the Fleet so fresh `Ready` servers spin up. Run this between test runs to get a clean slate.

#### Verify the Istio mesh

```bash
make verify-mesh
```

This checks: remote cluster discovery (`istiod` synced state), shared root CA fingerprint (must match on both clusters), and east-west gateway NLB addresses.

### Teardown

```bash
make teardown
```

Deletes both claims (cascades to all managed resources — EKS clusters, VPCs, IAM roles, OIDC providers) and removes the Crossplane XRDs and Compositions from the management cluster.

---

## Key Design Decisions

### Why auto-provisioned VPC per cluster?

Requiring the operator to pre-create a VPC and copy subnet IDs into the claim adds a manual step that breaks GitOps workflows. Each cluster getting its own VPC via the `vpc` package means:
- **One claim → full environment** - no out-of-band Terraform prerequisites
- **Non-overlapping CIDRs by design** - `10.100.0.0/16` for eu-west-1, `10.110.0.0/16` for us-east-1 - enables Transit Gateway peering without re-addressing
- **Subnet tags set correctly from the start** - `karpenter.sh/subnetzone` is applied at creation so Karpenter can immediately select subnets without extra tagging steps

To use an existing VPC, set `vpcId`, `subnetIds`, `subnetPrivateIds`, and `subnetPublicIds` in the claim - the VPC creation step is skipped entirely.

### Why OIDC auto-derived instead of specified in the claim?

The OIDC issuer URL (`oidc.eks.<region>.amazonaws.com/id/<hash>`) is generated by AWS when the EKS cluster is created - it cannot be known before the cluster exists. Requiring it in the claim means a two-step process: apply the claim, wait for EKS to create, look up the OIDC URL, add it to the claim, re-apply. Auto-derivation from `status.atProvider.identity` eliminates that loop - Crossplane's reconciler reads the value on the second cycle and creates the IAM Role automatically.

### Why `primary: true` on exactly one cluster?

The shared Istio root CA must be created once. In a real production setup this is typically done by Terraform before any EKS clusters exist. The `primary: true` flag gives you the same result declaratively - Crossplane creates the CA Certificate on the management cluster's cert-manager. All cluster-level `istio` packages then reference it via `namespace/secret` path.

If you have an existing CA (from Terraform or another PKI), set `primary: false` on all clusters and create the `istio-ca` Secret in cert-manager manually before applying any claims.

### Why nested XRs (not separate claims)?

The `eks-cluster` Composition creates `XVPC`, `XAgonesCluster` and `XIstio` composite resources inline. This means:
- **One `kubectl apply`** provisions everything
- **Lifecycle is tied** - deleting the cluster claim cascades to VPC, Agones, and Istio resources
- **Parameters flow down** - the EKS cluster endpoint, CA data, and OIDC issuer discovered by Crossplane are passed automatically to child packages (no manual copy step)

### Why `portName: http-rest` on the Agones allocator service?

The `http-` prefix is Istio's protocol sniffing convention. It tells Envoy to treat this port as HTTP/2 (which gRPC uses), enabling retries, timeouts, and header-based routing. Without this prefix, Istio treats the port as raw TCP and the VirtualService routing rules do not apply.

```yaml
# In agones package - Istio mode
service:
  http:
    portName: http-rest   # ← "http-" prefix = Istio applies L7 routing
    targetPort: 8443
```

### Why `AUTO_PASSTHROUGH` on the east-west gateway?

The east-west gateway uses SNI routing - it reads the TLS SNI field to determine which backend service to forward to, without terminating the TLS session. This means:
- The allocator's mTLS identity is preserved end-to-end
- No certificate pinning issues
- The gateway configuration is static - it works for any service, not just Agones

---

## Routing Logic Reference

### VirtualService (generated by istio package)

```
mesh-region: us-east-1  →  subset us-east-1  →  local agones-allocator
mesh-region: eu-west-1  →  subset eu-west-1  →  remote agones-allocator (via east-west GW)
<missing header>         →  HTTP 400
```

### DestinationRule subsets

```
subset: us-east-1   →  pods with label mesh-region=us-east-1
subset: eu-west-1   →  pods with label mesh-region=eu-west-1
                        + outlierDetection (eject after 5 consecutive errors)
```

The Agones allocator pods get `mesh-region: <region>` label from the agones package (injected when `istio.enabled: true`).

### Retry policy

```yaml
retries:
  attempts: 3
  perTryTimeout: 2s
  retryOn: 429,409,connect-failure,reset,refused-stream,unavailable,cancelled,
           retriable-status-codes,resource-exhausted
  retryRemoteLocalities: true   # ← allows cross-cluster retry
timeout: 6s
```

`retryRemoteLocalities: true` is what enables automatic failover - if the target regional allocator returns a retryable error (no servers available, connection refused), Envoy retries against other subsets.

---

## Production Notes

### VPC CIDR planning

The two clusters use non-overlapping /16 blocks (`10.100.0.0/16` and `10.110.0.0/16`). This is intentional - it enables AWS Transit Gateway peering between the VPCs if you want private east-west gateway connectivity without routing through the internet. Add further clusters on `10.120.0.0/16`, `10.130.0.0/16`, etc.

### Network connectivity between clusters

The east-west gateway NLBs are provisioned as **internal** (`aws-load-balancer-scheme: internal`) — they have no public IP and are only reachable within the AWS network. Cross-region traffic between the two clusters therefore requires connectivity inside AWS.

The east-west gateway NLB is currently set to `internet-facing` so the demo works out of the box without Transit Gateway. Port 15443 is the only port exposed — restrict inbound to the other cluster's NLB source IPs via a security group if needed.

**For production** switch to internal and connect via AWS Transit Gateway:
- Change `aws-load-balancer-scheme: internet-facing` → `internal` in `packages/istio/aws.yaml`
- Create a TGW in each region and attach both VPCs to it
- Add a route in each VPC's private route tables pointing the remote CIDR (`10.100.0.0/16` ↔ `10.110.0.0/16`) to the TGW
- Traffic stays on the AWS backbone, no public exposure

### Karpenter node consolidation for game servers

```yaml
disruption:
  consolidateAfter: 15m
  consolidationPolicy: WhenEmpty  # Only drain nodes with zero pods
template:
  spec:
    terminationGracePeriod: 15m   # Respect running game sessions
    expireAfter: Never            # Don't force-cycle running nodes
```

`WhenEmpty` is critical - `WhenUnderutilized` would evict game server pods mid-session.

### cert-manager CA rotation

The Istio root CA has a 10-year validity with 30-day renewal notice. cert-manager handles rotation automatically. When the CA rotates, istiod picks up the new `cacerts` secret on the next reconciliation cycle - workload certificates are re-issued transparently.

---

## Further Reading

- [Agones Multi-cluster Allocation](https://agones.dev/site/docs/guides/multi-cluster-allocation/)
- [Istio Multi-Primary on Different Networks](https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/)
- [Istio Plugin CA Certs](https://istio.io/latest/docs/tasks/security/cert-management/plugin-ca-cert/)
- [Crossplane Nested Composite Resources](https://docs.crossplane.io/latest/concepts/compositions/#nested-composite-resources)
- [Karpenter Disruption](https://karpenter.sh/docs/concepts/disruption/)
- [AWS EKS IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
