# Hermes Agent on Amazon EKS 部署指南

## 目录

- [1. 概述](#1-概述)
- [2. 架构总览](#2-架构总览)
- [3. 前置条件](#3-前置条件)
- [4. 基础设施部署 (Terraform)](#4-基础设施部署-terraform)
- [5. 验证集群状态](#5-验证集群状态)
- [6. 配置 LiteLLM 模型网关](#6-配置-litellm-模型网关)
- [7. 部署 Hermes Agent 沙箱](#7-部署-hermes-agent-沙箱)
- [8. 验证沙箱运行](#8-验证沙箱运行)
- [9. 可观测性](#9-可观测性)
- [10. 从 OpenClaw 迁移](#10-从-openclaw-迁移)
- [11. 运维操作](#11-运维操作)
- [12. 故障排查](#12-故障排查)
- [13. 资源清理](#13-资源清理)
- [附录 A: Terraform 变量参考](#附录-a-terraform-变量参考)
- [附录 B: Kata Hypervisor 选型](#附录-b-kata-hypervisor-选型)
- [附录 C: 项目文件结构](#附录-c-项目文件结构)

---

## 1. 概述

本文档描述如何在 Amazon EKS 上部署 Hermes Agent，使用 Kata Containers 提供 VM 级别的沙箱隔离。

**Hermes Agent** 是 Nous Research 开发的自进化 AI Agent 框架，支持：
- 40+ 内置工具（代码执行、文件操作、浏览器自动化、Web搜索等）
- 15+ 消息平台网关（飞书、Slack、Telegram、Discord、钉钉、企业微信等）
- 跨会话记忆持久化和技能自进化
- OpenAI 兼容 API（端口 8642）和 Web Dashboard（端口 9119）

**隔离方案**：每个 Hermes Agent Pod 运行在 Kata Containers 创建的独立 VM 中，Guest VM 拥有独立内核，攻击面从宿主机整个 Linux syscall 接口缩小到 Hypervisor 虚拟设备接口。

**预计部署时间**：15-20 分钟（基础设施） + 5 分钟（沙箱配置）

---

## 2. 架构总览

```
                         ┌──────────────────────────────────┐
                         │         Amazon EKS Cluster        │
                         │        (hermes-kata-eks)          │
  ┌──────────────────────┼──────────────────────────────────┤
  │                      │                                   │
  │  Core Node Group     │   Bare Metal Node Pool            │
  │  (m5.xlarge x2)     │   (c8i/m8i, nested KVM, Karpenter) │
  │                      │                                   │
  │  ┌────────────────┐  │   ┌─────────────────────────────┐ │
  │  │ litellm (ns)   │  │   │  Kata VM (Cloud Hypervisor) │ │
  │  │  LiteLLM Proxy │◄─┼───│  ┌───────────────────────┐  │ │
  │  │  Port 4000     │  │   │  │   Hermes Agent Pod    │  │ │
  │  └───────┬────────┘  │   │  │                       │  │ │
  │          │           │   │  │  gateway run           │  │ │
  │          ▼           │   │  │  API:  0.0.0.0:8642   │  │ │
  │  ┌────────────────┐  │   │  │  Dash: 0.0.0.0:9119  │  │ │
  │  │ Pod Identity   │  │   │  └───────────────────────┘  │ │
  │  │ → STS → Bedrock│  │   │  EBS gp3 2Gi → /opt/data   │ │
  │  └────────────────┘  │   └─────────────────────────────┘ │
  │                      │                                   │
  │  ┌────────────────┐  │   Namespace: hermes               │
  │  │ monitoring (ns)│  │   RuntimeClass: kata-clh          │
  │  │  Prometheus    │  │   ServiceAccount: hermes-sandbox  │
  │  │  Grafana       │  │                                   │
  │  └────────────────┘  │                                   │
  └──────────────────────┴───────────────────────────────────┘
                         │
              ┌──────────┴──────────┐
              ▼                     ▼
        Amazon Bedrock        消息平台
        (Claude Opus 4.6)     (飞书/Slack/Telegram...)
```

**Terraform 创建的资源清单**：

| 资源 | 说明 |
|---|---|
| VPC + 子网 | 3 AZ，公有+私有子网，单 NAT Gateway |
| EKS 集群 | Kubernetes 1.31，公开 API endpoint |
| Core 节点组 | 2x m5.xlarge，承载系统组件 |
| Karpenter | 按需供给 c8i/m8i 实例（嵌套 KVM），空闲 1 分钟回收 |
| Kata Containers | kata-deploy Helm chart，启用 QEMU + CLH |
| LiteLLM Proxy | 模型网关 + PostgreSQL + Pod Identity |
| EBS CSI Driver | gp3 动态卷供给 |
| EFS CSI Driver | 可选的共享存储，Access Point 隔离 |
| Prometheus + Grafana | 可观测性栈，50Gi 持久化存储 |
| AWS LB Controller | Ingress 支持 |
| hermes namespace | Hermes Agent 沙箱 + ServiceAccount + NetworkPolicy |

---

## 3. 前置条件

### 3.1 工具安装

| 工具 | 最低版本 | 验证命令 |
|---|---|---|
| AWS CLI | v2 | `aws --version` |
| kubectl | 1.28+ | `kubectl version --client` |
| Terraform | 1.3.2+ | `terraform --version` |
| Helm | v3.x | `helm version` |

### 3.2 AWS 权限

执行部署的 IAM 身份需要以下权限：

- **EKS**: `eks:*`（创建集群、节点组、Pod Identity Association）
- **EC2**: `ec2:*`（VPC、子网、安全组、c8i/m8i 实例）
- **IAM**: `iam:*`（创建 Role、Policy、OIDC Provider、Instance Profile）
- **EBS/EFS**: `elasticfilesystem:*`, EBS 相关权限
- **Bedrock**: `bedrock:InvokeModel`（LiteLLM 通过 Pod Identity 使用）
- **KMS**: `kms:*`（EKS 集群加密）
- **SQS**: `sqs:*`（Karpenter interruption queue）

建议使用 `AdministratorAccess` 或等效策略进行初始部署。

### 3.3 Bedrock 模型访问

确保目标 Region 已启用 Claude Opus 4.6 模型访问：

```bash
aws bedrock list-foundation-models \
  --region us-east-1 \
  --query "modelSummaries[?modelId=='anthropic.claude-opus-4-6-v1'].modelId"
```

如果返回为空，需要在 Bedrock 控制台申请模型访问权限。

### 3.4 Service Quota

确认 On-Demand Standard vCPU quota 充足（c8i/m8i 属于 Standard 实例族）：

```bash
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --region us-west-2 \
  --query 'Quota.Value'
```

`c8i.4xlarge` 需要 16 vCPU，建议 quota 至少 64。

---

## 4. 基础设施部署 (Terraform)

### 4.1 克隆仓库

```bash
git clone https://github.com/aws-samples/sample-aws-eks-kata-for-agents.git
cd aws-eks-kata-for-agents
```

### 4.2 一键部署（推荐）

```bash
chmod +x install.sh
./install.sh
```

支持自定义 Region 和集群名称：

```bash
./install.sh --region ap-southeast-1 --cluster-name my-hermes
```

脚本执行流程：
1. 检查 aws / kubectl / terraform / helm 是否已安装
2. `terraform init` 下载 provider 和 module
3. `terraform plan` 生成执行计划并等待确认
4. `terraform apply` 创建全部资源（约 15-20 分钟）
5. 自动配置 kubectl 上下文

### 4.3 手动部署（可选）

如果需要更细粒度的控制：

```bash
# 初始化
terraform init

# 查看/修改变量（可选）
cp terraform.tfvars.example terraform.tfvars
# 编辑 terraform.tfvars

# 计划
terraform plan -out=tfplan

# 部署
terraform apply tfplan

# 配置 kubectl
aws eks --region us-west-2 update-kubeconfig --name hermes-kata-eks
```

### 4.4 自定义变量

创建 `terraform.tfvars` 覆盖默认值：

```hcl
# 基础配置
name                = "my-hermes-cluster"
region              = "ap-southeast-1"
eks_cluster_version = "1.31"
vpc_cidr            = "10.1.0.0/16"

# Kata 配置
kata_hypervisor    = "clh"            # clh (推荐) | qemu | fc
kata_instance_types = ["c8i.2xlarge", "c8i.4xlarge", "m8i.2xlarge"]

# Hermes 配置
hermes_agent_image  = "nousresearch/hermes-agent:latest"
hermes_model_default = "openai/claude-opus-4-6"

# 中国区部署
is_china_region = false

# 额外的集群管理员
access_entries = {
  admin = {
    principal_arn = "arn:aws:iam::123456789012:role/AdminRole"
    policy_associations = {
      admin = {
        policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        access_scope = {
          type = "cluster"
        }
      }
    }
  }
}
```

---

## 5. 验证集群状态

Terraform 完成后，依次验证各组件：

### 5.1 集群连接

```bash
kubectl cluster-info
kubectl get nodes
```

预期输出：2 个 core 节点处于 `Ready` 状态。

### 5.2 Kata Containers

```bash
# 检查 kata-deploy Pod
kubectl get pods -n kata-system

# 检查 RuntimeClass
kubectl get runtimeclass
```

预期输出：`kata-qemu` 和 `kata-clh` 两个 RuntimeClass 可用。

### 5.3 Karpenter

```bash
# 检查 Karpenter controller
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter

# 检查 NodePool
kubectl get nodepool
kubectl get ec2nodeclass
```

预期输出：`kata-nested-kvm` NodePool 和 EC2NodeClass 已创建。此时尚无 Kata 节点——节点会在沙箱 Pod 调度时由 Karpenter 按需拉起。

### 5.4 LiteLLM

```bash
kubectl get pods -n litellm
kubectl get svc -n litellm
```

预期输出：litellm Pod 和 Service 处于 Running/ClusterIP 状态。

### 5.5 Monitoring

```bash
kubectl get pods -n monitoring
```

预期输出：prometheus 和 grafana Pod 均 Running。

### 5.6 Hermes Namespace

```bash
kubectl get ns hermes
kubectl get sa -n hermes
kubectl get networkpolicy -n hermes
kubectl get configmap -n hermes
```

预期输出：hermes namespace 已创建，包含 `hermes-sandbox` ServiceAccount、`hermes-sandbox-egress` NetworkPolicy、`hermes-base-config` ConfigMap。

---

## 6. 配置 LiteLLM 模型网关

### 6.1 获取 Master Key

```bash
MASTER_KEY=$(kubectl get secret litellm-masterkey -n litellm \
  -o jsonpath='{.data.masterkey}' | base64 -d)

echo "Master Key: $MASTER_KEY"
```

### 6.2 验证 Bedrock 连通性

发送测试请求，验证 Pod Identity → STS → Bedrock 完整链路：

```bash
kubectl run -n litellm test-bedrock --rm -i --restart=Never \
  --image=curlimages/curl -- \
  curl -s -X POST http://litellm:4000/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-opus-4-6",
    "messages": [{"role": "user", "content": "Say hello in one word"}],
    "max_tokens": 20
  }'
```

预期：收到包含模型回复的 JSON 响应。如果报错 `AccessDeniedException`，检查 Bedrock 模型访问权限和 Region 配置。

### 6.3 为沙箱生成 API Key

每个沙箱（或每批沙箱）应使用独立的 API Key，设置 30 天有效期：

```bash
LITELLM_API_KEY=$(kubectl run -n litellm gen-key --rm -i \
  --restart=Never --image=curlimages/curl -- \
  curl -s -X POST http://litellm:4000/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"models": ["claude-opus-4-6"], "duration": "30d"}' \
  | grep -o '"key":"[^"]*"' | cut -d'"' -f4)

echo "LiteLLM API Key: $LITELLM_API_KEY"
```

保存此 Key，后续步骤需要注入到沙箱配置中。

### 6.4 （可选）添加更多模型

如需对接硅基流动等其他模型提供商，修改 `litellm.tf` 中的 `model_list` 并重新 apply：

```hcl
model_list = [
  {
    model_name = "claude-opus-4-6"
    litellm_params = {
      model           = "bedrock/us.anthropic.claude-opus-4-6-v1"
      aws_region_name = "us-east-1"
    }
  },
  {
    model_name = "qwen-72b"
    litellm_params = {
      model    = "openai/Qwen/Qwen2.5-72B-Instruct"
      api_base = "https://api.siliconflow.cn/v1"
      api_key  = "sk-your-siliconflow-key"
    }
  }
]
```

```bash
terraform apply -target=helm_release.litellm
```

---

## 7. 部署 Hermes Agent 沙箱

### 7.1 选择消息平台

项目提供三个预置模板：

| 文件 | 消息平台 | 需要的凭据 |
|---|---|---|
| `examples/hermes-feishu-sandbox.yaml` | 飞书 | FEISHU_APP_ID, FEISHU_APP_SECRET |
| `examples/hermes-slack-sandbox.yaml` | Slack | SLACK_BOT_TOKEN, SLACK_APP_TOKEN |
| `examples/hermes-telegram-sandbox.yaml` | Telegram | TELEGRAM_BOT_TOKEN |

以下以飞书为例。Slack 和 Telegram 流程相同，替换对应的文件名和凭据即可。

### 7.2 准备凭据

```bash
# 设置环境变量
export FEISHU_APP_ID="cli_xxxxxxxxxx"
export FEISHU_APP_SECRET="xxxxxxxxxxxxxxxxxxxxxxxx"
export LITELLM_API_KEY="sk-xxxxxxxx"       # 步骤 6.3 生成的 Key
export API_SERVER_KEY=$(openssl rand -hex 32)
```

### 7.3 注入凭据到 YAML

```bash
cd examples

sed -i.bak \
  -e "s/YOUR_LITELLM_API_KEY/${LITELLM_API_KEY}/g" \
  -e "s/YOUR_FEISHU_APP_ID/${FEISHU_APP_ID}/g" \
  -e "s/YOUR_FEISHU_APP_SECRET/${FEISHU_APP_SECRET}/g" \
  -e "s/YOUR_API_SERVER_KEY/${API_SERVER_KEY}/g" \
  hermes-feishu-sandbox.yaml
```

### 7.4 部署

```bash
kubectl apply -f hermes-feishu-sandbox.yaml
```

该命令创建以下资源（全部在 `hermes` namespace）：

| 资源 | 名称 | 说明 |
|---|---|---|
| Secret | `hermes-feishu-secrets` | 飞书凭据 + API Server Key |
| ConfigMap | `hermes-feishu-config` | config.yaml + SOUL.md + .env |
| PVC | `hermes-feishu-data` | 2Gi EBS gp3 卷，挂载到 /opt/data |
| Pod | `hermes-feishu-sandbox` | Hermes Agent 主进程，kata-clh 隔离 |
| Service | `hermes-feishu-sandbox` | 暴露 8642 (API) + 9119 (Dashboard) |

### 7.5 首次启动等待

首次部署时，Karpenter 需要拉起 c8i/m8i 实例，预计等待时间：

| 阶段 | 耗时 |
|---|---|
| Karpenter 发现 pending Pod | ~10s |
| EC2 c8i/m8i 实例启动 | 30s-1 min |
| 节点加入集群 + kata-deploy 安装 | 1-2 min |
| 镜像拉取 (nousresearch/hermes-agent) | 1-3 min |
| Hermes Agent 初始化 | ~30s |
| **总计（冷启动）** | **3-6 min** |

后续部署（节点已存在）：约 1-3 分钟。

---

## 8. 验证沙箱运行

### 8.1 检查 Pod 状态

```bash
kubectl get pod hermes-feishu-sandbox -n hermes
```

预期：`Running`，`1/1 READY`

如果处于 `Pending`：

```bash
# 检查事件
kubectl describe pod hermes-feishu-sandbox -n hermes

# 检查 Karpenter 是否在供给节点
kubectl get nodes -l workload-type=kata
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50
```

### 8.2 查看日志

```bash
kubectl logs -f hermes-feishu-sandbox -n hermes
```

正常启动日志应包含：
- `Activating virtual environment`
- `Syncing skills`
- `Gateway starting`
- `Feishu platform connected`（或对应平台）

### 8.3 健康检查

```bash
# 基本健康检查
kubectl run test-health --rm -i --restart=Never \
  --image=curlimages/curl -- \
  curl -s http://hermes-feishu-sandbox.hermes:8642/health

# 详细状态
kubectl run test-health-detail --rm -i --restart=Never \
  --image=curlimages/curl -- \
  curl -s http://hermes-feishu-sandbox.hermes:8642/health/detailed
```

### 8.4 测试 API Server

```bash
kubectl run test-api --rm -i --restart=Never \
  --image=curlimages/curl -- \
  curl -s -X POST http://hermes-feishu-sandbox.hermes:8642/v1/chat/completions \
  -H "Authorization: Bearer ${API_SERVER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "hermes-agent",
    "messages": [{"role": "user", "content": "Hello, what can you do?"}],
    "max_tokens": 200
  }'
```

### 8.5 访问 Web Dashboard

```bash
kubectl port-forward -n hermes pod/hermes-feishu-sandbox 9119:9119
```

浏览器打开 `http://localhost:9119`，可查看配置、会话历史和环境变量。

### 8.6 端到端验证

在飞书（或 Slack / Telegram）中向 Bot 发送消息：

```
你好，请告诉我今天的日期，然后写一个Python脚本计算斐波那契数列前10项
```

确认能够收到正常回复，且 Agent 能够执行代码。

---

## 9. 可观测性

### 9.1 Grafana 登录

```bash
# 获取密码
terraform output -raw grafana_admin_password

# 端口转发
kubectl port-forward -n monitoring svc/grafana 3000:80
```

浏览器打开 `http://localhost:3000`，用户名 `admin`，密码为上面输出的值。

### 9.2 LiteLLM 监控

Prometheus 数据源已自动配置。LiteLLM 通过 Prometheus callback 暴露以下指标：

| 指标 | 说明 |
|---|---|
| `litellm_requests_total` | 请求总量（按模型、状态） |
| `litellm_request_duration_seconds` | 请求延迟分布 |
| `litellm_tokens_total` | Token 消耗（输入/输出） |
| `litellm_spend_total` | 费用追踪 |

可导入 `examples/grafana/grafana_dashboard.json` 获得预置面板。

### 9.3 Hermes Agent 监控

Hermes Agent 的 `/health/detailed` 端点返回以下信息：

- 活跃会话数和缓存状态
- 已连接的消息平台
- 工具和技能加载状态
- 内存使用

建议创建 Prometheus ServiceMonitor 定期抓取：

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: hermes-sandbox
  namespace: monitoring
spec:
  namespaceSelector:
    matchNames: ["hermes"]
  selector:
    matchLabels:
      app: hermes-sandbox
  endpoints:
    - port: api
      path: /health/detailed
      interval: 30s
```

### 9.4 Kata / 节点监控

Karpenter 和节点级别指标通过 kube-prometheus-stack 自动采集：

- 节点 CPU/内存/磁盘使用率
- Pod 启动延迟
- Karpenter provisioning 延迟和节点生命周期

---

## 10. 从 OpenClaw 迁移

如果你之前使用 OpenClaw 部署，Hermes Agent 内置迁移工具。

### 10.1 在 Pod 内迁移

如果 OpenClaw 数据已在 Pod 的 PVC 上：

```bash
kubectl exec -it hermes-feishu-sandbox -n hermes -- hermes claw migrate
```

迁移工具自动检测 `/opt/data/.openclaw`（以及 `.clawdbot`、`.moltbot`）目录，导入：

| 数据 | 目标位置 |
|---|---|
| SOUL.md | `/opt/data/SOUL.md` |
| 记忆系统 | `/opt/data/memories/` |
| 技能库 | `/opt/data/skills/` |
| 命令白名单 | `config.yaml` |
| 消息平台配置 | `.env` |
| API 密钥 | `.env` |
| TTS 资源 | `/opt/data/` |
| 工作区指令 | `/opt/data/workspace/` |

### 10.2 本地迁移后上传

```bash
# 本地执行迁移
hermes claw migrate

# 将数据同步到 PVC
kubectl cp ~/.hermes/memories/ hermes/hermes-feishu-sandbox:/opt/data/memories/
kubectl cp ~/.hermes/skills/ hermes/hermes-feishu-sandbox:/opt/data/skills/
```

### 10.3 基础设施层面的差异

| 方面 | OpenClaw | Hermes Agent |
|---|---|---|
| 需要 OpenClaw Operator | 是 (openclaw-operator Helm) | 否 |
| 需要 agent-sandbox CRD | 是 (manifest.yaml + extensions.yaml) | 否（原生 K8s 资源） |
| Terraform 文件 | `openclaw-operator.tf` + `agent-sandbox.tf` | `hermes-bedrock.tf` + `hermes-config.tf` |
| 沙箱定义方式 | `Sandbox` CRD | 标准 `Pod` + `Service` + `PVC` |
| 容器端口 | 18789 / 18790 | 8642 / 9119 |
| RuntimeClass | `kata-qemu` | `kata-clh`（推荐） |

---

## 11. 运维操作

### 11.1 更新 Hermes Agent 镜像

```bash
kubectl set image pod/hermes-feishu-sandbox \
  hermes=nousresearch/hermes-agent:v0.12.0 \
  -n hermes
```

或删除后重新 apply（PVC 数据不丢失）：

```bash
kubectl delete pod hermes-feishu-sandbox -n hermes
kubectl apply -f examples/hermes-feishu-sandbox.yaml
```

### 11.2 修改 Agent 配置

编辑 ConfigMap 后重启 Pod：

```bash
kubectl edit configmap hermes-feishu-config -n hermes
kubectl delete pod hermes-feishu-sandbox -n hermes
kubectl apply -f examples/hermes-feishu-sandbox.yaml
```

### 11.3 轮换 LiteLLM API Key

```bash
# 生成新 Key
NEW_KEY=$(kubectl run -n litellm gen-key --rm -i \
  --restart=Never --image=curlimages/curl -- \
  curl -s -X POST http://litellm:4000/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"models": ["claude-opus-4-6"], "duration": "30d"}' \
  | grep -o '"key":"[^"]*"' | cut -d'"' -f4)

# 更新 ConfigMap 中的 api_key
kubectl get configmap hermes-feishu-config -n hermes -o yaml \
  | sed "s/api_key: .*/api_key: \"$NEW_KEY\"/" \
  | kubectl apply -f -

# 重启 Pod
kubectl delete pod hermes-feishu-sandbox -n hermes
kubectl apply -f examples/hermes-feishu-sandbox.yaml
```

### 11.4 切换 Hypervisor

修改沙箱 YAML 中的 `runtimeClassName`：

```yaml
spec:
  runtimeClassName: kata-qemu   # 从 kata-clh 切换到 kata-qemu
```

重新 apply 即可。无需修改 Terraform 基础设施（两种 RuntimeClass 均已启用）。

### 11.5 扩展多个沙箱

复制示例 YAML，修改资源名称和凭据：

```bash
cp examples/hermes-feishu-sandbox.yaml examples/hermes-feishu-sandbox-2.yaml

# 修改所有资源名称（Secret/ConfigMap/PVC/Pod/Service）
sed -i 's/hermes-feishu/hermes-feishu-2/g' examples/hermes-feishu-sandbox-2.yaml

# 注入新的凭据
# ...

kubectl apply -f examples/hermes-feishu-sandbox-2.yaml
```

### 11.6 查看 PVC 数据

```bash
kubectl exec -it hermes-feishu-sandbox -n hermes -- ls -la /opt/data/
kubectl exec -it hermes-feishu-sandbox -n hermes -- du -sh /opt/data/*
```

---

## 12. 故障排查

### 12.1 Pod 一直 Pending

**原因 1**：Karpenter 未能拉起节点

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=100 | grep -i error
```

常见问题：
- Service Quota 不足 → 提交 quota increase 请求
- 目标 AZ 无 c8i/m8i 库存 → 添加更多 instance type 到 `kata_instance_types`

**原因 2**：kata-deploy 未完成安装

```bash
kubectl get pods -n kata-system
kubectl get runtimeclass
```

kata-deploy DaemonSet 需要在 Kata 节点上完成安装后，RuntimeClass 才可用。节点必须支持嵌套 KVM（/dev/kvm 可用）。

### 12.2 Pod CrashLoopBackOff

```bash
kubectl logs hermes-feishu-sandbox -n hermes --previous
```

常见问题：
- `.env` 中的消息平台凭据错误 → 核对 FEISHU_APP_ID / APP_SECRET
- LiteLLM API Key 无效 → 重新生成（步骤 6.3）
- 配置文件格式错误 → 检查 config.yaml YAML 语法

### 12.3 Bedrock 调用失败

```bash
# 检查 LiteLLM Pod Identity
kubectl describe sa litellm -n litellm
kubectl logs -n litellm -l app.kubernetes.io/name=litellm --tail=50
```

常见问题：
- Pod Identity Agent 未安装 → `kubectl get ds -n kube-system | grep pod-identity`
- IAM Role 权限不足 → 检查 `hermes-kata-eks-litellm-pod-identity` Role 的 Policy
- 目标 Region 未启用模型 → 检查 Bedrock 控制台的 Model access

### 12.4 网络问题

```bash
# 检查 NetworkPolicy
kubectl get networkpolicy -n hermes

# 从沙箱 Pod 内测试连通性
kubectl exec -it hermes-feishu-sandbox -n hermes -- \
  curl -s -o /dev/null -w "%{http_code}" http://litellm.litellm:4000/health
```

NetworkPolicy 允许：
- → LiteLLM (litellm namespace, port 4000)
- → DNS (port 53)
- → HTTPS/HTTP 出站 (port 443/80)

### 12.5 存储问题

```bash
# 检查 PVC 状态
kubectl get pvc -n hermes

# 检查 EBS CSI Driver
kubectl get pods -n kube-system -l app=ebs-csi-controller
```

PVC 状态为 `Pending` 通常表示 EBS CSI Driver 问题或 AZ 不匹配（WaitForFirstConsumer 模式下 PVC 等待 Pod 调度后才绑定）。

---

## 13. 资源清理

### 13.1 仅删除沙箱

```bash
kubectl delete -f examples/hermes-feishu-sandbox.yaml
```

PVC 默认使用 `Delete` 回收策略，Pod 删除后 EBS 卷自动释放。

### 13.2 完整清理

```bash
# 删除所有沙箱
kubectl delete -f examples/ --ignore-not-found=true

# 等待 Pod 终止
sleep 30

# 销毁全部 Terraform 资源
terraform destroy
```

或使用脚本：

```bash
chmod +x cleanup.sh
./cleanup.sh
```

> **注意**：`terraform destroy` 会删除 VPC、EKS 集群、所有 EBS/EFS 卷、IAM 资源。此操作不可逆。

---

## 附录 A: Terraform 变量参考

| 变量 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `name` | string | `hermes-kata-eks` | 集群和 VPC 名称 |
| `region` | string | `us-west-2` | AWS Region |
| `eks_cluster_version` | string | `1.31` | Kubernetes 版本 |
| `vpc_cidr` | string | `10.1.0.0/16` | VPC CIDR |
| `kata_hypervisor` | string | `clh` | Hypervisor: `qemu` / `clh` / `fc` |
| `kata_instance_types` | list(string) | `[c8i.2xlarge, c8i.4xlarge, m8i.2xlarge, m8i.4xlarge]` | 支持嵌套 KVM 的实例类型 |
| `is_china_region` | bool | `null` (自动检测) | 是否中国区 |
| `access_entries` | any | `{}` | EKS 集群访问条目 |
| `kms_key_admin_roles` | list(string) | `[]` | KMS 管理员角色 |
| `hermes_agent_image` | string | `nousresearch/hermes-agent:latest` | Agent 镜像 |
| `hermes_model_default` | string | `openai/claude-opus-4-6` | 默认模型 |

---

## 附录 B: Kata Hypervisor 选型

本项目默认使用 **Cloud Hypervisor (CLH)**，同时启用 QEMU 作为备选。

| 维度 | Cloud Hypervisor | QEMU | Firecracker |
|---|---|---|---|
| **推荐度** | 首选 | 保底 | 高密度场景 |
| virtio-fs | 支持 | 支持 | 不支持 |
| 热插拔 | 支持 | 支持 | 不支持 |
| 启动速度 | ~200ms | ~500ms+ | ~125ms |
| 内存开销 | ~10-20MB/VM | ~30-130MB/VM | ~5MB/VM |
| EBS 支持 | virtio-blk | virtio-blk | virtio-blk |
| EFS 支持 | 支持 | 支持 | 不推荐 |
| 额外配置 | 无 | 无 | 需要 devmapper |
| 从 QEMU 迁移 | 改 RuntimeClass 即可 | 当前方案 | 需要节点配置 |

**为什么不推荐 gVisor**：gVisor 不是 Kata 后端，而是独立的隔离方案。其 syscall 兼容性不完整，对于需要运行任意 Python 代码、pip install、apt-get 的 AI Agent 沙箱，存在不可预测的兼容性风险。详见 [docs/isolation-backends-analysis.md](./isolation-backends-analysis.md)。

---

## 附录 C: 项目文件结构

```
.
├── main.tf                  # Provider 配置和 locals
├── variables.tf             # 输入变量定义
├── outputs.tf               # 输出值
├── versions.tf              # Terraform 和 Provider 版本约束
│
├── vpc.tf                   # VPC + 子网 + NAT Gateway
├── eks.tf                   # EKS 集群 + Core 节点组
├── karpenter.tf             # Karpenter + nested KVM NodePool (c8i/m8i)
│
├── kata.tf                  # kata-system + hermes namespace
├── kata-deploy.tf           # Kata Containers Helm release
│
├── litellm.tf               # LiteLLM Proxy + Pod Identity + Bedrock IAM
├── hermes-bedrock.tf        # Hermes Pod 直连 Bedrock 的 IRSA (可选)
├── hermes-config.tf         # 基础 ConfigMap + NetworkPolicy
│
├── ebs-csi-driver.tf        # EBS CSI Driver IRSA
├── ebs-storageclass.tf      # gp3 StorageClass (default)
├── efs-csi-driver.tf        # EFS 文件系统 + CSI Driver + StorageClass
├── eks-blueprints-addons.tf # AWS Load Balancer Controller
├── monitoring.tf            # Prometheus + Grafana
│
├── install.sh               # 一键部署脚本
├── cleanup.sh               # 一键清理脚本
│
├── examples/
│   ├── hermes-feishu-sandbox.yaml     # 飞书沙箱 (Secret+CM+PVC+Pod+Svc)
│   ├── hermes-slack-sandbox.yaml      # Slack 沙箱
│   ├── hermes-telegram-sandbox.yaml   # Telegram 沙箱
│   └── grafana/
│       └── grafana_dashboard.json     # LiteLLM Grafana 面板
│
└── docs/
    ├── deployment-guide.md            # 本文档
    ├── blog-hermes-agent.md           # Hermes Agent 版本博客
    ├── blog.md                        # 原始 OpenClaw 博客
    └── isolation-backends-analysis.md # Kata 隔离后端技术分析
```
