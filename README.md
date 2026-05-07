# AI Agent Sandbox on Amazon EKS with Kata Containers

Deploy [Hermes Agent](https://github.com/nousresearch/hermes-agent), [OpenClaw](https://github.com/openclaw/openclaw), or [RayClaw](https://github.com/rayclaw/rayclaw) on Amazon EKS with VM-level sandbox isolation via Kata Containers.

Supports **multi-agent-runtime, multi-tenant** deployment — run Hermes Agent, OpenClaw, and RayClaw sandboxes side by side with per-tenant network isolation and LiteLLM API key management.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   Amazon EKS                         │
│                                                      │
│  ┌──────────────┐  ┌──────────────────────────────┐ │
│  │  Core Nodes   │  │  Kata Nodes (EKS MNG)        │ │
│  │  (m5.xlarge)  │  │  (m8i, nested KVM enabled)   │ │
│  │               │  │                              │ │
│  │  LiteLLM      │  │  ┌────────────────────────┐ │ │
│  │  Prometheus   │  │  │  Kata VM (CLH/QEMU)    │ │ │
│  │  Grafana      │  │  │  ┌──────────────────┐  │ │ │
│  │               │  │  │  │ Hermes Agent    │  │ │ │
│  │               │  │  │  │ Port 8642/9119  │  │ │ │
│  │               │  │  │  └─────────────────┘  │ │ │
│  │               │  │  │  ┌─────────────────┐  │ │ │
│  │               │  │  │  │ OpenClaw        │  │ │ │
│  │               │  │  │  │ Port 19001      │  │ │ │
│  │               │  │  │  └─────────────────┘  │ │ │
│  │               │  │  │  ┌─────────────────┐  │ │ │
│  │               │  │  │  │ RayClaw         │  │ │ │
│  │               │  │  │  │ Port 10962      │  │ │ │
│  │               │  │  │  └─────────────────┘  │ │ │
│  │               │  │  │  EBS Vol (per-pod)    │ │ │
│  │               │  │  └────────────────────────┘ │ │
│  └──────────────┘  └──────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
         │                        │
         ▼                        ▼
   Amazon Bedrock          Feishu / Slack /
   (via LiteLLM)           Telegram / Discord
```

## Components

| Component | Purpose |
|---|---|
| **EKS** | Managed Kubernetes control plane |
| **Karpenter** | Auto-provision nodes for general workloads |
| **EKS Managed Node Group** | Kata nodes with nested KVM (c8i/m8i/r8i) or bare-metal instances |
| **Kata Containers** | VM-level isolation per sandbox pod (QEMU + CLH) |
| **LiteLLM** | Unified model gateway (Bedrock, SiliconFlow, etc.) |
| **Hermes Agent** | AI agent with multi-platform messaging (gateway run) |
| **OpenClaw** | AI agent with WebSocket gateway (gateway mode) |
| **RayClaw** | Rust-based AI agent with multi-channel support (private ECR image) |
| **Prometheus + Grafana** | Observability stack |

## Supported Agent Runtimes

| Aspect | Hermes Agent | OpenClaw | RayClaw |
|---|---|---|---|
| Image | `nousresearch/hermes-agent` | `ghcr.io/openclaw/openclaw` | Private ECR (self-built) |
| Data path | `/opt/data` | `/home/node/.openclaw` | `/data` |
| Entry command | `gateway run` (via entrypoint) | `node openclaw.mjs gateway` | `rayclaw` (single binary) |
| Gateway port | 8642 (API) / 9119 (Dashboard) | 19001 (WebSocket) | 10962 (Web) |
| Config format | `config.yaml` (YAML) | `openclaw.json` (JSON) | `rayclaw.config.yaml` (YAML) |
| Model config | `model.default` + `model.base_url` | `models.providers` + `models.default` | `llm_provider` + `llm_base_url` |
| User ID | 0 (drops to 10000 via gosu) | 1000 (node) | 1000 (rayclaw) |
| Channels | Feishu, Slack, Telegram, Discord, WhatsApp | Feishu, Slack, Telegram, Discord, WhatsApp, iMessage, Line, Matrix, Teams, + 13 more | Feishu, Slack, Telegram, Discord, WeChat, Web |

All three runtimes share the same infrastructure: EKS, Karpenter, Kata, LiteLLM, NetworkPolicy, and multi-tenant isolation.

## Prerequisites

- AWS CLI configured
- kubectl
- Terraform >= 1.3.2
- Helm v3.x

## Quick Start

```bash
git clone https://github.com/aws-samples/sample-aws-eks-kata-for-agents.git
cd aws-eks-kata-for-agents
chmod +x install.sh
./install.sh
```

Custom region/name:

```bash
./install.sh --region ap-southeast-1 --cluster-name my-hermes
```

### Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `--region` | AWS region | `us-west-2` |
| `--cluster-name` | EKS cluster name | `hermes-kata-eks` |
| `--kata-mode` | Kata node mode: `nested-kvm` or `bare-metal` | `nested-kvm` |
| `--kata-instance-types` | Comma-separated instance types for Kata nodes | `m8i.2xlarge,m8i.4xlarge` |
| `--help` | Show usage and examples | — |

```bash
./install.sh --kata-mode nested-kvm                        # Default: 8i instances with nested KVM
./install.sh --kata-mode bare-metal                        # Bare metal instances (native /dev/kvm)
./install.sh --kata-mode nested-kvm --kata-instance-types c8i.4xlarge,c8i.8xlarge
./install.sh --help                                        # Show all options
```

### Kata Node Modes

The Kata worker nodes support two modes for hardware virtualization:

| Mode | Instance Types | How KVM is Provided |
|------|---------------|-------------------|
| `nested-kvm` (default) | m8i, c8i, r8i families | `CpuOptions.NestedVirtualization=enabled` at launch |
| `bare-metal` | *.metal instances | Native `/dev/kvm` on bare metal |

```bash
# Default: m8i instances with nested KVM enabled
./install.sh --kata-mode nested-kvm

# Use specific 8i instance types
./install.sh --kata-mode nested-kvm --kata-instance-types c8i.4xlarge,c8i.8xlarge

# Bare metal instances (native KVM, no nested virt needed)
./install.sh --kata-mode bare-metal --kata-instance-types m5.metal
```

> **Note:** Karpenter does not support `CpuOptions.NestedVirtualization`. Kata nodes are
> provisioned as an EKS Managed Node Group with a launch template created via AWS CLI.

### Generate LiteLLM API Key

```bash
MASTER_KEY=$(kubectl get secret litellm-masterkey -n litellm \
  -o jsonpath='{.data.masterkey}' | base64 -d)

LITELLM_API_KEY=$(kubectl run -n litellm gen-key --rm -i \
  --restart=Never --image=curlimages/curl -- \
  curl -s -X POST http://litellm:4000/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"models": ["claude-opus-4-6"], "duration": "30d"}' \
  | grep -o '"key":"[^"]*"' | cut -d'"' -f4)
```

### Verify Bedrock Connectivity

```bash
kubectl run -n litellm test --rm -i --restart=Never \
  --image=curlimages/curl -- \
  curl -s -X POST http://litellm:4000/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-opus-4-6", "messages": [{"role": "user", "content": "Hi"}], "max_tokens": 20}'
```

### Deploy a Sandbox

#### Hermes Agent

```bash
cd examples
# Edit hermes-feishu-sandbox.yaml — replace YOUR_LITELLM_API_KEY and platform credentials
sed -i.bak \
  -e "s/YOUR_LITELLM_API_KEY/${LITELLM_API_KEY}/g" \
  -e "s/YOUR_FEISHU_APP_ID/${FEISHU_APP_ID}/g" \
  -e "s/YOUR_FEISHU_APP_SECRET/${FEISHU_APP_SECRET}/g" \
  hermes-feishu-sandbox.yaml

kubectl apply -f hermes-feishu-sandbox.yaml
```

Also available: `hermes-slack-sandbox.yaml`, `hermes-telegram-sandbox.yaml`

#### OpenClaw

```bash
cd examples
# Edit openclaw-feishu-sandbox.yaml — replace YOUR_LITELLM_API_KEY and platform credentials
sed -i.bak \
  -e "s/YOUR_LITELLM_API_KEY/${LITELLM_API_KEY}/g" \
  -e "s/YOUR_FEISHU_APP_ID/${FEISHU_APP_ID}/g" \
  -e "s/YOUR_FEISHU_APP_SECRET/${FEISHU_APP_SECRET}/g" \
  openclaw-feishu-sandbox.yaml

kubectl apply -f openclaw-feishu-sandbox.yaml
```

Also available: `openclaw-slack-sandbox.yaml`, `openclaw-telegram-sandbox.yaml`

#### RayClaw

RayClaw requires building the image from source and pushing to your private ECR (no public image available):

```bash
# Clone RayClaw source and build to ECR
git clone https://github.com/rayclaw/rayclaw ~/rayclaw
./scripts/build-rayclaw-ecr.sh --source ~/rayclaw --region us-west-2

# Update the example YAML with your ECR URI and credentials
cd examples
sed -i.bak \
  -e "s|ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/rayclaw:latest|YOUR_ECR_URI|g" \
  -e "s/YOUR_LITELLM_API_KEY/${LITELLM_API_KEY}/g" \
  -e "s/YOUR_FEISHU_APP_ID/${FEISHU_APP_ID}/g" \
  -e "s/YOUR_FEISHU_APP_SECRET/${FEISHU_APP_SECRET}/g" \
  rayclaw-feishu-sandbox.yaml

kubectl apply -f rayclaw-feishu-sandbox.yaml
```

Also available: `rayclaw-slack-sandbox.yaml`, `rayclaw-telegram-sandbox.yaml`

### Verify

```bash
kubectl get pods -n hermes
kubectl logs -f hermes-feishu-sandbox -n hermes
```

### Access Dashboard

```bash
kubectl port-forward -n hermes pod/hermes-feishu-sandbox 9119:9119
# Open http://localhost:9119
```

## Kata Hypervisor Selection

Default: **Cloud Hypervisor (CLH)** -- best balance of performance and compatibility.

| Feature | QEMU | CLH | Firecracker |
|---|---|---|---|
| virtio-fs | Yes | Yes | No |
| Hotplug | Yes | Yes | No |
| Boot time | ~500ms | ~200ms | ~125ms |
| Memory/VM | ~30-130MB | ~10-20MB | ~5MB |

Switch hypervisor via RuntimeClass in sandbox YAML:

```yaml
spec:
  runtimeClassName: kata-clh    # or kata-qemu
```

See [docs/isolation-backends-analysis.md](docs/isolation-backends-analysis.md) for detailed comparison including Firecracker and gVisor.

### Kata Networking Limitations

Kata VMs on EKS with VPC CNI have specific networking constraints:

- **ClusterIP unreachable** — Kata VMs cannot access Kubernetes Service ClusterIPs (kube-proxy iptables rules don't apply to VM tap traffic)
- **NodePort unreachable** — Same reason as ClusterIP
- **Pod-to-pod via Pod IP** — Only works within the same security group

**Workarounds applied in this project:**
- DNS: Pods use VPC DNS (`dnsPolicy: None` + VPC CIDR base+2) instead of CoreDNS ClusterIP
- LiteLLM: Exposed via `hostPort` on core nodes; Kata pods access it via node IP
- Security groups: A rule allows traffic from Kata nodes (cluster primary SG) to core nodes (node SG)

## Monitoring

```bash
# Grafana password
terraform output -raw grafana_admin_password

# Port forward
kubectl port-forward -n monitoring svc/grafana 3000:80
```

## Cleanup

```bash
./cleanup.sh --cluster-name my-hermes --region us-west-2
```

## File Structure

```
.
├── main.tf                  # Providers and locals
├── variables.tf             # Input variables
├── outputs.tf               # Output values
├── versions.tf              # Terraform/provider versions
├── vpc.tf                   # VPC with public/private subnets
├── eks.tf                   # EKS cluster and core node group
├── karpenter.tf             # Karpenter for general workloads
├── kata-nodegroup.tf        # Kata EKS Managed Node Group (nested-kvm / bare-metal)
├── kata.tf                  # Namespaces (kata-system, hermes)
├── kata-deploy.tf           # Kata Containers Helm release
├── litellm.tf               # LiteLLM proxy + Bedrock IAM
├── hermes-bedrock.tf        # IRSA for direct Bedrock access
├── hermes-config.tf         # Base ConfigMap + NetworkPolicy
├── ebs-csi-driver.tf        # EBS CSI driver IRSA
├── ebs-storageclass.tf      # gp3 StorageClass
├── efs-csi-driver.tf        # EFS + CSI driver + StorageClass
├── eks-blueprints-addons.tf # AWS LB Controller
├── monitoring.tf            # Prometheus + Grafana
├── install.sh               # Deployment script
├── cleanup.sh               # Teardown script
├── hermes-tenants.tf        # Multi-tenant key provisioning
├── scripts/
│   └── build-rayclaw-ecr.sh   # Build RayClaw image → private ECR
├── examples/
│   ├── hermes-feishu-sandbox.yaml
│   ├── hermes-slack-sandbox.yaml
│   ├── hermes-telegram-sandbox.yaml
│   ├── openclaw-feishu-sandbox.yaml
│   ├── openclaw-slack-sandbox.yaml
│   ├── openclaw-telegram-sandbox.yaml
│   ├── rayclaw-feishu-sandbox.yaml
│   ├── rayclaw-slack-sandbox.yaml
│   ├── rayclaw-telegram-sandbox.yaml
│   └── grafana/
│       └── grafana_dashboard.json
└── docs/
    ├── blog-hermes-agent.md
    ├── blog.md
    ├── deployment-guide.md
    ├── multi-tenancy-guide.md
    └── isolation-backends-analysis.md
```
