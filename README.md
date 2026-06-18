# Multi-Region Game Server Allocation on EKS with Agones and Istio

> **TL;DR** — This repository contains production-tested Crossplane packages that wire together EKS, Agones, and Istio into a self-managing multi-region game server platform. A matchmaker sends one gRPC call; Istio's service mesh routes it to the nearest available game server — regardless of which cluster it lives in.

---

## The Problem: Players Hate Lag, Matchmakers Hate Complexity

Imagine you run a competitive online game. Your players span three continents. You want to always allocate the nearest game server, but you also need global failover when a region is under pressure. And your matchmaker shouldn't need to know the topology of your infrastructure.

The naive solution — one cluster per region, a load balancer per cluster, custom logic in the matchmaker — falls apart quickly. You end up with N different endpoints to manage, N certificate rotations, and a matchmaker that's become an infrastructure component.

The elegant solution is Agones multi-cluster allocation over an Istio service mesh. The matchmaker sends one request to a single virtual endpoint. The mesh routes it. The allocation happens wherever there's capacity.

This post shows you how to build exactly that — declaratively, using Crossplane.

---

## Architecture Overview

```
                          ┌─────────────────────────────────────────────────┐
                          │              Crossplane Management Cluster      │
                          │                                                 │
                          │  ┌──────────────┐    ┌──────────────────────┐   │
                          │  │  kubernetes  │    │   agones + istio     │   │
                          │  │   package    │    │     packages         │   │
                          │  └──────────────┘    └──────────────────────┘   │
                          └─────────────────────────────────────────────────┘
                                        │                   │
                         ┌──────────────┘                   └──────────────┐
                         ▼                                                 ▼
          ┌──────────────────────────┐                  ┌──────────────────────────┐
          │   EKS Cluster us-east-1  │                  │   EKS Cluster eu-west-1  │
          │                          │                  │                          │
          │  ┌────────────────────┐  │                  │  ┌────────────────────┐  │
          │  │  istiod            │  │◄── mTLS mesh ───►│  │  istiod            │  │
          │  │  east-west gateway │  │   (port 15443)   │  │  east-west gateway │  │
          │  └────────────────────┘  │                  │  └────────────────────┘  │
          │                          │                  │                          │
          │  ┌────────────────────┐  │                  │  ┌────────────────────┐  │
          │  │  agones-allocator  │  │                  │  │  agones-allocator  │  │
          │  │  (ClusterIP + Istio│  │                  │  │  (ClusterIP + Istio│  │
          │  │   sidecar)         │  │                  │  │   sidecar)         │  │
          │  └────────────────────┘  │                  │  └────────────────────┘  │
          │                          │                  │                          │
          │  ┌────────────────────┐  │                  │  ┌────────────────────┐  │
          │  │  Game Servers      │  │                  │  │  Game Servers      │  │
          │  │  (Karpenter SPOT)  │  │                  │  │  (Karpenter SPOT)  │  │
          │  └────────────────────┘  │                  │  └────────────────────┘  │
          └──────────────────────────┘                  └──────────────────────────┘
                         ▲                                           ▲
                         │            mesh-region: eu-west-1         │
                         └───────────── Matchmaker ──────────────────┘
                                    (single gRPC endpoint)
```

The matchmaker sets a `mesh-region` header on its allocation request. Istio's VirtualService routes it to the correct regional subset. If the local cluster has capacity, it handles the allocation locally. If not — thanks to `retryRemoteLocalities: true` — Istio retries transparently against another region.

---

## Why Crossplane Packages?

Before diving into the code, let's talk about the delivery model.

Instead of writing Terraform or Helm values files per environment, we define **Crossplane Compositions** — reusable templates that accept parameters and produce real cloud resources. A "claim" is just a small YAML file that says *what* you want; the Composition says *how* to build it.

The three packages in this repository follow a layered model:

```
packages/
├── eks-cluster/    # EKS + IAM + addons + Karpenter + cert-manager
├── agones/         # Agones HA + Karpenter NodePools for game servers  
└── istio/          # Istio control plane + east-west gateway + mesh routing rules
```

This mirrors the delivery chain: infrastructure first, then Agones, then the service mesh on top.

---

## Package 1: EKS Cluster

The `eks-cluster` package provisions everything a production EKS cluster needs: IAM roles, node groups, EKS addons, Karpenter for dynamic scaling, and cert-manager for certificate management.

The definition (`packages/eks-cluster/definition.yaml`) exposes a clean API:

```yaml
apiVersion: demo.crossplane.io/v1alpha1
kind: KubernetesCluster
metadata:
  name: gameserver-us-east-1
  namespace: demo
spec:
  id: gameserver-us-east-1
  parameters:
    region: us-east-1
    version: "1.32"
    awsAccountNumber: "123456789012"
    vpcId: vpc-0123456789abcdef0
    subnetIds: [...]
    karpenterVersion: "1.4.0"
    # Toggle the entire Agones stack on/off
    agones:
      enabled: true
      version: "1.48.0"
    # Toggle the Istio service mesh
    istio:
      enabled: true
      version: "1.26.2"
      meshID: demo-mesh
      multicluster:
        enabled: true
        rules:
        - clusterName: gameserver-eu-west-1
          region: eu-west-1
```

The Composition (`packages/eks-cluster/aws.yaml`) translates this into EKS cluster, IAM roles, node groups, addons, Karpenter, and cert-manager — all as Crossplane managed resources that are continuously reconciled.

Key excerpt from the Composition — game server UDP port exposure:

```yaml
# Security group rule: game server UDP ports
apiVersion: ec2.aws.upbound.io/v1beta1
kind: SecurityGroupRule
metadata:
  name: {{ $id }}-sgr-gameserver-udp
spec:
  forProvider:
    region: {{ $params.region }}
    cidrBlocks:
    - 0.0.0.0/0
    fromPort: 7000
    toPort: 8000
    protocol: udp
    type: ingress
```

---

## Package 2: Agones with Istio-Aware Configuration

The `agones` package handles the Agones installation. The interesting part is how it switches behavior based on whether Istio is present.

**Without Istio**, the Agones allocator uses NLB + direct mTLS:

```yaml
# Non-Istio mode: NLB with direct mTLS
service:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
  grpc:
    enabled: true
    port: 8443
```

**With Istio**, the allocator becomes a ClusterIP service. TLS is disabled on the allocator itself — Istio's mTLS handles it transparently:

```yaml
# Istio mode: ClusterIP — east-west gateway handles cross-cluster routing
{{- if $istioEnabled }}
- name: agones.allocator.disableTLS
  value: "true"
{{- end }}

service:
  {{- if $istioEnabled }}
  annotations:
    blitz.agones.dev/allocator-host: agones-allocator.agones-system.svc.cluster.local
  serviceType: ClusterIP
  http:
    enabled: true
    port: 443
    portName: http-rest    # Prefix 'http-' tells Istio to use HTTP protocol with mTLS
    targetPort: 8443
  {{- end }}
```

The `portName: http-rest` naming convention is crucial — the `http-` prefix signals to Istio that it should treat this port as HTTP (enabling features like retries, timeouts, and header-based routing), while still wrapping it in mTLS.

The `agones-system` namespace gets the Istio network label, which is required for service discovery across clusters:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: agones-system
  labels:
    istio-injection: enabled
    # Required for Istio multi-network/multicluster service discovery
    topology.istio.io/network: {{ $id }}-istio-network
```

---

## Package 3: Istio — The Mesh That Connects Everything

This is where the magic happens. The Istio package (`packages/istio/aws.yaml`) does several things:

### Shared Root CA for Cross-Cluster mTLS

For mTLS to work across clusters, all clusters must share the same root CA. Crossplane copies the CA from the management cluster's cert-manager secret into each workload cluster's `cacerts` secret:

```yaml
# cacerts secret consumed by istiod for signing workload certificates.
# All clusters must share the same root CA for cross-cluster mTLS to work.
apiVersion: v1
kind: Secret
metadata:
  name: cacerts
  namespace: istio-system
type: Opaque
data:
  root-cert.pem: {{ $rootCertB64 | quote }}
  ca-cert.pem: {{ $caCertB64 | quote }}
  ca-key.pem: {{ $caKeyB64 | quote }}
  cert-chain.pem: {{ $certChainB64 | quote }}
```

### meshNetworks — Mapping Networks to Gateways

The `meshNetworks` configuration in istiod tells the control plane how to reach services in other clusters. Each entry maps a network name to the east-west gateway that fronts it:

```yaml
global:
  meshID: demo-mesh
  meshNetworks:
    # Local cluster
    gameserver-us-east-1-istio-network:
      endpoints:
        - fromRegistry: gameserver-us-east-1
      gateways:
        - registryServiceName: gameserver-us-east-1-istio-eastwestgateway.istio-system.svc.cluster.local
          port: 15443
    # Remote cluster — eu-west-1
    gameserver-eu-west-1-istio-network:
      endpoints:
        - fromRegistry: gameserver-eu-west-1
      gateways:
        - registryServiceName: gameserver-eu-west-1-istio-eastwestgateway.istio-system.svc.cluster.local
          port: 15443
  multiCluster:
    clusterName: gameserver-us-east-1
  network: gameserver-us-east-1-istio-network
```

### East-West Gateway

The east-west gateway is the cross-cluster data plane. It exposes port 15443 with `AUTO_PASSTHROUGH` mode — Istio SNI-routes traffic to the correct service on the remote cluster without terminating TLS:

```yaml
# cross-network-gateway: tells the east-west gateway to auto-passthrough
# TLS for any *.local host — required for cross-cluster service access.
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: cross-network-gateway
  namespace: istio-system
spec:
  selector:
    istio: eastwestgateway
  servers:
  - port:
      number: 15443
      name: tls
      protocol: TLS
    tls:
      mode: AUTO_PASSTHROUGH
    hosts:
    - "*.local"
```

The gateway itself gets an AWS NLB via annotations:

```yaml
service:
  type: LoadBalancer
  ports:
  - name: tls
    port: 15443
    targetPort: 15443
    nodePort: 31443
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-attributes: load_balancing.cross_zone.enabled=true
```

### Remote Secrets — The Cluster Discovery Mechanism

For each cluster to discover services in other clusters, istiod needs credentials to read the remote Kubernetes API. These are called "remote secrets."

Crossplane automates this: each cluster's Istio package creates a remote secret for itself, then copies the remote secrets from peer clusters:

```yaml
# Remote secret for THIS cluster — placed on every peer cluster so istiod
# there can discover services running here.
apiVersion: v1
kind: Secret
metadata:
  name: istio-remote-secret-gameserver-us-east-1
  namespace: istio-system
  annotations:
    networking.istio.io/cluster: gameserver-us-east-1
  labels:
    istio/multiCluster: "true"
stringData:
  gameserver-us-east-1: |
    apiVersion: v1
    clusters:
    - cluster:
        certificate-authority-data: <ca-data>
        server: https://<api-endpoint>
      name: gameserver-us-east-1
    ...
    users:
    - name: gameserver-us-east-1
      user:
        token: <istio-reader-token>
```

### Header-Based Routing for Regional Allocation

The VirtualService is where the routing logic lives. The matchmaker sets a `mesh-region` header, and Istio routes the request to the corresponding regional subset:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: allocator-multicluster
  namespace: agones-system
spec:
  hosts:
  - agones-allocator.agones-system.svc.cluster.local
  http:
  # Route to us-east-1 allocators
  - match:
    - headers:
        mesh-region:
          exact: us-east-1
    retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: 429,409,connect-failure,reset,refused-stream,unavailable,cancelled,retriable-status-codes,resource-exhausted
      retryRemoteLocalities: true
    timeout: 6s
    route:
    - destination:
        host: agones-allocator.agones-system.svc.cluster.local
        subset: us-east-1
        port:
          number: 443
  # Route to eu-west-1 allocators (cross-cluster via east-west gateway)
  - match:
    - headers:
        mesh-region:
          exact: eu-west-1
    retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: 429,409,connect-failure,reset,refused-stream,unavailable,cancelled,retriable-status-codes,resource-exhausted
      retryRemoteLocalities: true
    timeout: 6s
    route:
    - destination:
        host: agones-allocator.agones-system.svc.cluster.local
        subset: eu-west-1
        port:
          number: 443
  # Fallback: reject requests with missing/unknown mesh-region header
  - directResponse:
      status: 400
      body:
        string: '{"message":"missing or invalid mesh-region header"}'
    headers:
      response:
        set:
          content-type: application/json
```

The DestinationRule marks each regional allocator deployment with a subset label:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: allocator-multicluster
  namespace: agones-system
spec:
  host: agones-allocator.agones-system.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
  subsets:
  - name: us-east-1
    labels:
      mesh-region: us-east-1
  - name: eu-west-1
    labels:
      mesh-region: eu-west-1
    trafficPolicy:
      tls:
        mode: ISTIO_MUTUAL
      outlierDetection:
        consecutiveErrors: 5
        interval: 30s
        baseEjectionTime: 30s
```

And the Agones allocator pod gets the `mesh-region` label so Istio can select the right subset:

```yaml
# In the agones package, the allocator gets a region label
allocator:
  labels:
    mesh-region: us-east-1
  annotations:
    sidecar.istio.io/inject: "true"
```

---

## Deployment Walk-Through

### Prerequisites

- Crossplane installed on a management cluster
- Crossplane providers: `provider-aws`, `provider-kubernetes`, `provider-helm`
- Crossplane functions: `function-go-templating`, `function-auto-ready`
- A shared cert-manager CA secret named `istio-ca` in the `cert-manager` namespace

### Step 1 — Install the Crossplane packages

```bash
kubectl apply -f packages/eks-cluster/
kubectl apply -f packages/agones/
kubectl apply -f packages/istio/
```

### Step 2 — Claim the first cluster (us-east-1)

```bash
kubectl apply -f examples/cluster-us-east-1.yaml
```

Crossplane starts reconciling. Watch progress:

```bash
kubectl get kubernetescluster gameserver-us-east-1 -w
kubectl get managed -l crossplane.io/claim-name=gameserver-us-east-1
```

The EKS cluster, IAM roles, node groups, Karpenter, and cert-manager are all created automatically. Once the cluster is `ACTIVE`, apply the Agones and Istio claims:

```bash
kubectl apply -f examples/agones-claim-us-east-1.yaml
kubectl apply -f examples/istio-claim-us-east-1.yaml
```

### Step 3 — Claim the second cluster (eu-west-1)

```bash
kubectl apply -f examples/cluster-eu-west-1.yaml
# ... wait for cluster to be ACTIVE ...
kubectl apply -f examples/agones-claim-eu-west-1.yaml  # create from the example template
kubectl apply -f examples/istio-claim-eu-west-1.yaml
```

### Step 4 — Verify cross-cluster connectivity

Once both clusters are up, verify the east-west gateways can reach each other:

```bash
# On cluster us-east-1
kubectl get svc -n istio-system gameserver-us-east-1-istio-eastwestgateway

# Check istiod has discovered remote services
istioctl remote-clusters --context=gameserver-us-east-1
# Should show: gameserver-eu-west-1  synced

# Verify remote secrets are present
kubectl get secrets -n istio-system -l istio/multiCluster=true
# Should show secrets for both clusters
```

### Step 5 — Test multi-region allocation

Deploy a Fleet on each cluster:

```yaml
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
          - key: agones.dev/agones-gameservers-amd64
            operator: Equal
            value: "true"
            effect: NoExecute
          containers:
          - name: server
            image: us-docker.pkg.dev/agones-images/examples/simple-game-server:0.34
```

Allocate a game server targeting `eu-west-1` from the `us-east-1` cluster:

```bash
# Using grpc-curl or agones-allocator client
# The mesh-region header tells Istio which region to route to
kubectl exec -it deploy/agones-allocator -n agones-system -- \
  /allocator \
  --host=agones-allocator.agones-system.svc.cluster.local:443 \
  --namespace=agones-gameservers \
  --multicluster=true \
  --header="mesh-region: eu-west-1"
```

The request travels: local allocator → Istio sidecar → east-west gateway (us-east-1) → east-west gateway (eu-west-1) → remote allocator → game server assigned.

---

## Production Considerations

### Karpenter for Game Server Nodes

Game servers have a unique scaling pattern: you need nodes fast when a match starts, but you want to drain them quickly when they finish. Karpenter handles this well with the `WhenEmpty` consolidation policy:

```yaml
disruption:
  consolidateAfter: 15m
  consolidationPolicy: WhenEmpty  # Only consolidate nodes with no pods
template:
  spec:
    terminationGracePeriod: 15m   # Wait for game sessions to finish
    expireAfter: Never            # Don't force-expire running game servers
```

The `taintKey` pattern ensures game server pods only land on game server nodes (and vice versa):

```yaml
taints:
- effect: NoExecute
  key: agones.dev/agones-gameservers-amd64
  value: "true"
```

### Agones Topology Spread Constraints

The allocator replicas spread across AZs for HA:

```yaml
topologySpreadConstraints:
- labelSelector:
    matchLabels:
      multicluster.agones.dev/role: allocator
  maxSkew: 1
  topologyKey: topology.kubernetes.io/zone
  whenUnsatisfiable: DoNotSchedule
```

### Istio Outlier Detection

The DestinationRule includes outlier detection for remote regions — if an allocator starts failing, Istio temporarily ejects it from the load balancing pool:

```yaml
outlierDetection:
  consecutiveErrors: 5
  interval: 30s
  baseEjectionTime: 30s
```

### Certificate Rotation

All certificates are managed by cert-manager with 10-year validity and 10-hour renewal windows. The Agones webhook certificates are auto-injected via cert-manager annotations, so rotation is zero-touch.

### Istiod High Availability

The istiod deployment has HPA and topology spread constraints to ensure it survives an AZ outage without impacting the data plane:

```yaml
pilot:
  autoscaleEnabled: true
  autoscaleMin: 2   # Floor of 2 + AZ spread: drain-safe with PDB minAvailable=1
  autoscaleMax: 5
```

---

## How This Compares to the Alternative

| Approach | Management overhead | Matchmaker complexity | Cross-region latency |
|---|---|---|---|
| One NLB per cluster | High (N certs, N endpoints) | High (knows all regions) | Optimal if client-side routing |
| Agones multicluster (no Istio) | Medium (cert sync automation needed) | Low | Optimal |
| **Agones + Istio (this repo)** | **Low (Crossplane manages everything)** | **Very low (one endpoint)** | **Optimal + automatic failover** |

The Istio approach adds a small data-plane hop (through the east-west gateway) compared to direct NLB, but the operational benefits and the automatic retry/failover behavior more than compensate.

---

## Repository Structure

```
.
├── README.md                          # This article
├── packages/
│   ├── eks-cluster/
│   │   ├── crossplane.yaml            # Package metadata
│   │   ├── definition.yaml            # XRD: KubernetesCluster API
│   │   └── aws.yaml                   # Composition: EKS + IAM + addons + Karpenter
│   ├── agones/
│   │   ├── crossplane.yaml
│   │   ├── definition.yaml            # XRD: AgonesCluster API
│   │   └── aws.yaml                   # Composition: Agones HA + NodePools
│   └── istio/
│       ├── crossplane.yaml
│       ├── definition.yaml            # XRD: Istio API
│       └── aws.yaml                   # Composition: istiod + east-west GW + mesh routing
└── examples/
    ├── cluster-us-east-1.yaml         # EKS claim: us-east-1
    ├── cluster-eu-west-1.yaml         # EKS claim: eu-west-1
    ├── agones-claim-us-east-1.yaml    # Agones claim: us-east-1
    └── istio-claim-us-east-1.yaml     # Istio claim: us-east-1
```

---

## Key Takeaways

1. **Istio's `mesh-region` header routing** eliminates the need for the matchmaker to know cluster topology. One endpoint, any region.

2. **`retryRemoteLocalities: true`** gives you automatic cross-region failover without any application code changes.

3. **The `portName: http-` convention** is the critical bridge between Agones (which speaks gRPC/HTTP2) and Istio's traffic management features.

4. **Crossplane Compositions** handle the operational complexity: remote secrets, CA certificate distribution, and routing rule generation are all driven by simple YAML parameters.

5. **Karpenter's `WhenEmpty` + `terminationGracePeriod`** is the right combination for game server workloads — you get fast scale-up, economical scale-down, and respect for running game sessions.

---

## Further Reading

- [Agones Multi-cluster Allocation](https://agones.dev/site/docs/guides/multi-cluster-allocation/)
- [Istio Multi-Primary on Different Networks](https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/)
- [Crossplane Compositions](https://docs.crossplane.io/latest/concepts/compositions/)
- [Karpenter NodePools](https://karpenter.sh/docs/concepts/nodepools/)

---

*The packages in this repository are stripped-down, demo-ready versions. They cover the core mechanics — EKS provisioning, Agones HA, and Istio multi-cluster mesh — without organization-specific configuration. Fork, adapt the `awsAccountNumber` and VPC parameters, and you have a working foundation.*
