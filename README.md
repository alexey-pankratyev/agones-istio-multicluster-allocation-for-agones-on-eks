# Multi-Region Game Server Allocation on EKS with Agones and Istio

> This project deploys a multi-region game server infrastructure on Amazon EKS using Crossplane — a single claim per region provisions the full stack: VPC with public and private subnets, EKS, Agones allocator, Karpenter SPOT node pools, and an Istio multi-primary mesh — with OIDC/IRSA roles derived automatically from cluster status; two clusters form one Istio mesh with a shared mTLS root CA and east-west gateways for cross-cluster traffic; the matchmaker calls a single local gRPC endpoint — Istio routes allocation requests by `mesh-region` header and retries across regions on failure, no per-region endpoint logic required in application code.

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

**One claim per cluster.** The `eks-cluster` Composition first creates a `XVPC` nested XR (networking), then calls the `agones` and `istio` packages as further nested composite resources — you do not apply separate VPC, Agones, or Istio claims.

---

## Architecture

### Networking: Auto-Provisioned VPC per Cluster

Each cluster gets its own VPC created automatically by the `vpc` package. No pre-existing subnets or VPC IDs are required in the claim — just specify a CIDR block and the availability zones.

```
vpc.cidr: 10.100.0.0/16  (eu-west-1)     vpc.cidr: 10.110.0.0/16  (us-east-1)
availabilityZones:                        availabilityZones:
  - eu-west-1a                              - us-east-1a
  - eu-west-1b                              - us-east-1b

Per AZ layout (eu-west-1, /16 base = 10.100):
  AZ 0 (eu-west-1a):  private 10.100.0.0/24   public 10.100.100.0/24
  AZ 1 (eu-west-1b):  private 10.100.1.0/24   public 10.100.101.0/24

Resources created per AZ:
  • Private subnet  — tagged karpenter.sh/subnetzone=<az>         (Agones system nodes)
  • Public subnet   — tagged karpenter.sh/subnetzone=<az>-public  (game server nodes)
  • Elastic IP + NAT Gateway in the public subnet
  • Private route table routing 0.0.0.0/0 → NAT GW
Public route table (shared) routing 0.0.0.0/0 → Internet Gateway
```

The Karpenter `EC2NodeClass` subnet selectors default to the first AZ's tags (`<region>a` and `<region>a-public`) when not overridden in the claim.

To use an existing VPC instead, set `vpcId`, `subnetIds`, `subnetPrivateIds`, and `subnetPublicIds` explicitly in the claim — the XVPC step is skipped in that case.

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

### OIDC / IRSA — Auto-Derived

The `agones` package creates an IAM Role for the `agones-sdk` ServiceAccount (IRSA) so game server pods can call AWS APIs (e.g. S3 for replays). The OIDC issuer URL for this trust policy is **read automatically** from `status.atProvider.identity[0].oidc[0].issuer` of the EKS cluster — you do not need to specify it in the claim.

The flow across reconcile cycles:
1. **Cycle 1** — EKS cluster is created; OIDC issuer appears in its status.
2. **Cycle 2** — `eks-cluster` composition reads the issuer URL, strips `https://`, and passes it as `oidc` to the `XAgonesCluster` nested XR.
3. **Cycle 2** — `agones` composition creates the `<id>-role-agones-sdk` IAM Role with the correct OIDC federated trust policy.

The `oidc` field still exists in the `agones` XRD as an optional override for cases where an existing role or a specific issuer URL must be used.

### Agones Multi-Cluster Allocation Flow

The matchmaker pod runs **inside one of the clusters** (e.g. us-east-1). It calls the local agones-allocator service. Istio intercepts the call on the sidecar and, based on the `mesh-region` header, routes it to the appropriate regional allocator — either locally or across clusters via the east-west gateway.

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

| Component | Purpose |
|---|---|
| Management EKS cluster | Runs Crossplane, cert-manager |
| Crossplane ≥ 2.1.4 | Composition engine |
| `provider-aws` (upbound) | EKS, IAM, EC2, VPC resources |
| `provider-kubernetes` | Kubernetes Object resources |
| `provider-helm` | Helm Release resources |
| `function-go-templating` | Go template Composition function |
| `function-auto-ready` | Readiness detection function |

### Step 1 - Install Crossplane packages on the management cluster

```bash
kubectl apply -f packages/vpc/
kubectl apply -f packages/eks-cluster/
kubectl apply -f packages/agones/
kubectl apply -f packages/istio/
```

Wait for XRDs to become established:

```bash
kubectl wait xrd xvpcs.demo.crossplane.io                 --for=condition=Established --timeout=60s
kubectl wait xrd xkubernetesclusters.demo.crossplane.io   --for=condition=Established --timeout=60s
kubectl wait xrd xagonesclusters.demo.crossplane.io       --for=condition=Established --timeout=60s
kubectl wait xrd xistios.demo.crossplane.io               --for=condition=Established --timeout=60s
```

### Step 2 - Create the namespace for claims

```bash
kubectl create namespace demo
```

### Step 3 - Apply the primary cluster claim (us-east-1)

```bash
kubectl apply -f examples/cluster-us-east-1.yaml
```

This claim has `istio.primary: true`. The Composition will:
1. Create the Istio root CA (`istio-ca` Secret) in `cert-manager` on the management cluster
2. Provision a VPC (`10.110.0.0/16`) with public and private subnets in us-east-1a and us-east-1b
3. Provision the EKS cluster in us-east-1 (version 1.35) wired to the new subnets
4. Install cert-manager, Karpenter 1.13.0, EKS addons
5. Install Agones 1.55.0 via the `agones` nested XR; IRSA role created automatically once OIDC issuer appears in EKS status
6. Install Istio (istiod + east-west gateway) via the `istio` nested XR

Watch progress:

```bash
# Overall claim status
kubectl get kubernetescluster gameserver-us-east-1 -n demo -w

# All managed resources
kubectl get managed -l crossplane.io/claim-name=gameserver-us-east-1 -n demo

# VPC and subnets
kubectl get vpc.ec2.aws.upbound.io,subnet.ec2.aws.upbound.io \
  -l crossplane.io/composite=gameserver-us-east-1-vpc

# EKS cluster
kubectl get cluster.eks.aws.upbound.io gameserver-us-east-1 -w
```

### Step 4 - Apply the secondary cluster claim (eu-west-1)

```bash
kubectl apply -f examples/cluster-eu-west-1.yaml
```

This claim has `istio.primary: false`. The Composition will:
1. Provision a VPC (`10.100.0.0/16`) with public and private subnets in eu-west-1a and eu-west-1b
2. Provision the EKS cluster in eu-west-1
3. Install the same base components
4. Install Agones with `istio.enabled: true`; OIDC auto-derived as in us-east-1
5. Copy the `istio-ca` Secret from `cert-manager` into this cluster's `istio-system`
6. Install Istio pointing at us-east-1 as a peer cluster

### Step 5 - Verify the Istio mesh

After both clusters are ready, verify cross-cluster service discovery:

```bash
# Get kubeconfigs written by ClusterAuth
kubectl get secret gameserver-us-east-1-kubeconfig -n crossplane-system -o jsonpath='{.data.kubeconfig}' | base64 -d > /tmp/us-east-1.kubeconfig
kubectl get secret gameserver-eu-west-1-kubeconfig -n crossplane-system -o jsonpath='{.data.kubeconfig}' | base64 -d > /tmp/eu-west-1.kubeconfig

# Check remote cluster discovery from us-east-1
istioctl remote-clusters --kubeconfig=/tmp/us-east-1.kubeconfig
# NAME                      SECRET                                    STATUS    ISTIOD
# gameserver-eu-west-1      istio-remote-secret-gameserver-eu-west-1  synced    istiod-xxx

# Verify east-west gateways are reachable
kubectl get svc --kubeconfig=/tmp/us-east-1.kubeconfig -n istio-system \
  gameserver-us-east-1-istio-eastwestgateway
# Should show an EXTERNAL-IP (NLB hostname)

# Verify cacerts are present and identical on both clusters
kubectl get secret cacerts -n istio-system --kubeconfig=/tmp/us-east-1.kubeconfig \
  -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -noout -fingerprint

kubectl get secret cacerts -n istio-system --kubeconfig=/tmp/eu-west-1.kubeconfig \
  -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -noout -fingerprint
# Fingerprints must match - same root CA
```

### Step 6 - Deploy a Fleet and test allocation

Deploy the same Fleet on both clusters:

```bash
cat <<EOF | kubectl apply --kubeconfig=/tmp/us-east-1.kubeconfig -f -
apiVersion: agones.dev/v1
kind: Fleet
metadata:
  name: demo-gameserver
  namespace: agones-gameservers
spec:
  replicas: 5
  template:
    spec:
      ports:
      - name: default
        containerPort: 7777
      template:
        spec:
          tolerations:
          - key: agones.dev/agones-gameservers-arm64
            operator: Equal
            value: "true"
            effect: NoExecute
          containers:
          - name: server
            image: us-docker.pkg.dev/agones-images/examples/simple-game-server:0.34
EOF

# Same on eu-west-1
cat <<EOF | kubectl apply --kubeconfig=/tmp/eu-west-1.kubeconfig -f -
apiVersion: agones.dev/v1
kind: Fleet
metadata:
  name: demo-gameserver
  namespace: agones-gameservers
spec:
  replicas: 5
  template:
    spec:
      ports:
      - name: default
        containerPort: 7777
      template:
        spec:
          tolerations:
          - key: agones.dev/agones-gameservers-arm64
            operator: Equal
            value: "true"
            effect: NoExecute
          containers:
          - name: server
            image: us-docker.pkg.dev/agones-images/examples/simple-game-server:0.34
EOF
```

Test allocation targeting eu-west-1 from a pod running in us-east-1:

```bash
# Run a test pod on us-east-1
kubectl run allocator-test --kubeconfig=/tmp/us-east-1.kubeconfig \
  --image=ghcr.io/googleforgames/agones/allocator:1.55.0 \
  --restart=Never --rm -it -- /bin/sh

# Inside the pod - allocate from eu-west-1 via the mesh
# The mesh-region header tells Istio's VirtualService which subset to route to
grpc_cli call \
  agones-allocator.agones-system.svc.cluster.local:443 \
  agones.dev.Allocator.Allocate \
  "namespace: 'agones-gameservers', multi_cluster_setting: {enabled: true}" \
  --metadata "mesh-region:eu-west-1"
# Returns a GameServer from eu-west-1 cluster
```

---

## Key Design Decisions

### Why auto-provisioned VPC per cluster?

Requiring the operator to pre-create a VPC and copy subnet IDs into the claim adds a manual step that breaks GitOps workflows. Each cluster getting its own VPC via the `vpc` package means:
- **One claim → full environment** — no out-of-band Terraform prerequisites
- **Non-overlapping CIDRs by design** — `10.100.0.0/16` for eu-west-1, `10.110.0.0/16` for us-east-1 — enables Transit Gateway peering without re-addressing
- **Subnet tags set correctly from the start** — `karpenter.sh/subnetzone` is applied at creation so Karpenter can immediately select subnets without extra tagging steps

To use an existing VPC, set `vpcId`, `subnetIds`, `subnetPrivateIds`, and `subnetPublicIds` in the claim — the VPC creation step is skipped entirely.

### Why OIDC auto-derived instead of specified in the claim?

The OIDC issuer URL (`oidc.eks.<region>.amazonaws.com/id/<hash>`) is generated by AWS when the EKS cluster is created — it cannot be known before the cluster exists. Requiring it in the claim means a two-step process: apply the claim, wait for EKS to create, look up the OIDC URL, add it to the claim, re-apply. Auto-derivation from `status.atProvider.identity` eliminates that loop — Crossplane's reconciler reads the value on the second cycle and creates the IAM Role automatically.

### Why `primary: true` on exactly one cluster?

The shared Istio root CA must be created once. In a real production setup this is typically done by Terraform before any EKS clusters exist. The `primary: true` flag gives you the same result declaratively — Crossplane creates the CA Certificate on the management cluster's cert-manager. All cluster-level `istio` packages then reference it via `namespace/secret` path.

If you have an existing CA (from Terraform or another PKI), set `primary: false` on all clusters and create the `istio-ca` Secret in cert-manager manually before applying any claims.

### Why nested XRs (not separate claims)?

The `eks-cluster` Composition creates `XVPC`, `XAgonesCluster` and `XIstio` composite resources inline. This means:
- **One `kubectl apply`** provisions everything
- **Lifecycle is tied** — deleting the cluster claim cascades to VPC, Agones, and Istio resources
- **Parameters flow down** — the EKS cluster endpoint, CA data, and OIDC issuer discovered by Crossplane are passed automatically to child packages (no manual copy step)

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

The east-west gateway uses SNI routing — it reads the TLS SNI field to determine which backend service to forward to, without terminating the TLS session. This means:
- The allocator's mTLS identity is preserved end-to-end
- No certificate pinning issues
- The gateway configuration is static — it works for any service, not just Agones

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

`retryRemoteLocalities: true` is what enables automatic failover — if the target regional allocator returns a retryable error (no servers available, connection refused), Envoy retries against other subsets.

---

## Production Notes

### VPC CIDR planning

The two clusters use non-overlapping /16 blocks (`10.100.0.0/16` and `10.110.0.0/16`). This is intentional — it enables AWS Transit Gateway peering between the VPCs if you want private east-west gateway connectivity without routing through the internet. Add further clusters on `10.120.0.0/16`, `10.130.0.0/16`, etc.

### Network connectivity between clusters

The east-west gateways communicate over the internet (or via Transit Gateway if you prefer private routing). The NLBs are internal by default in this configuration (`aws-load-balancer-scheme: internal`). For cross-region connectivity you need either:

- AWS Transit Gateway connecting both VPCs (recommended — keeps traffic on AWS backbone)
- Or change `aws-load-balancer-scheme: internet-facing` and restrict with security groups

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

`WhenEmpty` is critical — `WhenUnderutilized` would evict game server pods mid-session.

### cert-manager CA rotation

The Istio root CA has a 10-year validity with 30-day renewal notice. cert-manager handles rotation automatically. When the CA rotates, istiod picks up the new `cacerts` secret on the next reconciliation cycle — workload certificates are re-issued transparently.

---

## Further Reading

- [Agones Multi-cluster Allocation](https://agones.dev/site/docs/guides/multi-cluster-allocation/)
- [Istio Multi-Primary on Different Networks](https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/)
- [Istio Plugin CA Certs](https://istio.io/latest/docs/tasks/security/cert-management/plugin-ca-cert/)
- [Crossplane Nested Composite Resources](https://docs.crossplane.io/latest/concepts/compositions/#nested-composite-resources)
- [Karpenter Disruption](https://karpenter.sh/docs/concepts/disruption/)
- [AWS EKS IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
