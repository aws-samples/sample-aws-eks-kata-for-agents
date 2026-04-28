# Hermes Agent 多租户使用指南

本文档介绍如何在 AWS EKS + Kata Containers 平台上以多租户模式运行 Hermes Agent，实现团队间的网络隔离、费用管控和流量限制。

## 架构概览

```
                    ┌─────────────────────────────────────────────────┐
                    │               hermes namespace                  │
                    │                                                 │
                    │  ┌─────────────┐       ┌─────────────┐         │
                    │  │  Tenant A   │  ✕✕✕  │  Tenant B   │         │
                    │  │ (team-alpha)│  deny  │ (team-beta) │         │
                    │  │  Slack Pod  │◄─────►│Telegram Pod │         │
                    │  └──────┬──────┘       └──────┬──────┘         │
                    │         │ allow               │ allow          │
                    └─────────┼─────────────────────┼─────────────── │
                              │                     │
                    ┌─────────▼─────────────────────▼──────┐
                    │           litellm namespace           │
                    │  ┌──────────────────────────────┐    │
                    │  │         LiteLLM Proxy         │    │
                    │  │  Key A: $10/月, 30 RPM        │    │
                    │  │  Key B: $5/月,  10 RPM        │    │
                    │  └──────────────┬───────────────┘    │
                    └─────────────────┼────────────────────┘
                                      │
                              ┌───────▼───────┐
                              │ Amazon Bedrock │
                              │  Claude Opus   │
                              └───────────────┘
```

**隔离维度：**

| 维度 | 实现方式 | 效果 |
|------|----------|------|
| 网络 | `deny-inter-pod-ingress` NetworkPolicy | 租户 Pod 之间完全不可达 |
| 费用 | LiteLLM per-key `max_budget` | 每租户独立预算上限 |
| 流量 | LiteLLM per-key `rpm_limit` / `tpm_limit` | 每租户独立限流 |
| 模型 | LiteLLM per-key `models` ACL | 每租户只能访问授权模型 |
| 存储 | 每租户独立 PVC | 数据物理隔离 |
| 配置 | 每租户独立 ConfigMap + Secret | 凭据不共享 |

## 快速开始

### 1. 定义租户

在 `terraform.tfvars`（或 `-var` 命令行）中声明租户：

```hcl
hermes_tenants = {
  team-alpha = {
    platform    = "slack"
    max_budget  = 20          # 预算上限 $20
    rpm_limit   = 30          # 每分钟 30 请求
    tpm_limit   = 100000      # 每分钟 10 万 token
    models      = ["claude-opus-4-6"]
  }
  team-beta = {
    platform       = "telegram"
    max_budget     = 5         # 预算上限 $5
    rpm_limit      = 10        # 每分钟 10 请求
    tpm_limit      = 50000
    budget_duration = "7d"     # 预算周期 7 天（默认 30d）
  }
}
```

### 2. 应用 Terraform

```bash
terraform apply -var="name=my-hermes" -var-file=terraform.tfvars
```

Terraform 会自动为每个租户：
- 调用 LiteLLM `/key/generate` API 生成独立 API Key
- 将 Key 存入 Kubernetes Secret `hermes-{tenant}-litellm`
- 创建租户专属 ConfigMap `hermes-{tenant}-config`

### 3. 查看生成的租户资源

```bash
# 查看所有租户 Secret
kubectl get secrets -n hermes -l app=hermes-sandbox

# 查看某租户的 API Key
kubectl get secret hermes-team-alpha-litellm -n hermes \
  -o jsonpath='{.data.api_key}' | base64 -d

# 查看租户 ConfigMap
kubectl get configmap -n hermes -l app=hermes-sandbox
```

### 4. 部署租户沙箱 Pod

以 `team-alpha`（Slack）为例，创建 `team-alpha-sandbox.yaml`：

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: hermes-team-alpha-secrets
  namespace: hermes
type: Opaque
stringData:
  SLACK_BOT_TOKEN: "xoxb-your-bot-token"
  SLACK_APP_TOKEN: "xapp-your-app-token"
  API_SERVER_KEY: "your-api-server-key"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hermes-team-alpha-data
  namespace: hermes
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ebs-sc
  resources:
    requests:
      storage: 2Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: hermes-team-alpha-sandbox
  namespace: hermes
  labels:
    app: hermes-sandbox          # 必须 — 触发 NetworkPolicy
    tenant: team-alpha           # 必须 — 租户标识
    platform: slack
spec:
  serviceAccountName: hermes-sandbox
  containers:
    - name: hermes
      image: nousresearch/hermes-agent:latest
      args: ["gateway", "run"]
      ports:
        - containerPort: 8642
          name: api
        - containerPort: 9119
          name: dashboard
      env:
        - name: LITELLM_API_KEY
          valueFrom:
            secretKeyRef:
              name: hermes-team-alpha-litellm    # Terraform 自动生成
              key: api_key
      envFrom:
        - secretRef:
            name: hermes-team-alpha-secrets
      volumeMounts:
        - name: data
          mountPath: /opt/data
        - name: config
          mountPath: /opt/data/config.yaml
          subPath: config.yaml
        - name: config
          mountPath: /opt/data/SOUL.md
          subPath: SOUL.md
      resources:
        requests:
          cpu: "1"
          memory: "1Gi"
        limits:
          cpu: "2"
          memory: "2Gi"
      securityContext:
        runAsUser: 0
        runAsGroup: 0
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: hermes-team-alpha-data
    - name: config
      configMap:
        name: hermes-team-alpha-config           # Terraform 自动生成
---
apiVersion: v1
kind: Service
metadata:
  name: hermes-team-alpha-sandbox
  namespace: hermes
spec:
  selector:
    app: hermes-sandbox
    tenant: team-alpha
  ports:
    - name: api
      port: 8642
      targetPort: 8642
    - name: dashboard
      port: 9119
      targetPort: 9119
```

部署：

```bash
kubectl apply -f team-alpha-sandbox.yaml
```

## 租户变量参考

`hermes_tenants` 变量的完整参数说明：

```hcl
variable "hermes_tenants" {
  type = map(object({
    platform        = string                              # 消息平台类型
    max_budget      = optional(number, 10)                # 预算上限（美元）
    rpm_limit       = optional(number, 30)                # 每分钟请求数上限
    tpm_limit       = optional(number, 100000)            # 每分钟 Token 数上限
    models          = optional(list(string), ["claude-opus-4-6"])  # 允许的模型列表
    budget_duration = optional(string, "30d")             # 预算重置周期
  }))
}
```

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `platform` | string | (必填) | 消息平台：`slack`、`telegram`、`feishu` 等 |
| `max_budget` | number | `10` | 预算上限（美元），超出后 API 请求被拒绝 |
| `rpm_limit` | number | `30` | 每分钟请求数上限 |
| `tpm_limit` | number | `100000` | 每分钟 Token 数上限 |
| `models` | list(string) | `["claude-opus-4-6"]` | 该租户允许调用的模型列表 |
| `budget_duration` | string | `"30d"` | 预算周期，支持 `1d`、`7d`、`30d` 等 |

## 自动生成的资源

每个租户在 `terraform apply` 后自动创建以下资源：

| 资源类型 | 命名格式 | 内容 |
|----------|----------|------|
| Kubernetes Secret | `hermes-{tenant}-litellm` | `api_key`（LiteLLM 生成的独立 Key）、`tenant` |
| Kubernetes ConfigMap | `hermes-{tenant}-config` | `config.yaml`（模型/LiteLLM 配置）、`SOUL.md`（系统提示词） |
| LiteLLM Virtual Key | alias: `tenant-{tenant}` | 绑定 budget、RPM/TPM 限制、模型 ACL |

## 网络策略详解

### Pod 间隔离（Ingress）

```
deny-inter-pod-ingress:
  podSelector: { app: hermes-sandbox }
  policyTypes: [Ingress]
  ingress: []      ← 空 = 拒绝所有入站流量
```

效果：所有带 `app=hermes-sandbox` 标签的 Pod **互相不可访问**。租户 A 无法连接租户 B 的 8642 或 9119 端口。

### 出站限制（Egress）

```
hermes-sandbox-egress:
  podSelector: { app: hermes-sandbox }
  policyTypes: [Egress]
  egress:
    - to: litellm namespace → port 4000/TCP    ✅ LiteLLM 代理
    - to: any namespace     → port 53/UDP+TCP  ✅ DNS 解析
    - to: 0.0.0.0/0         → port 443+80/TCP  ✅ HTTPS（消息平台、包安装）
```

效果：沙箱 Pod 只能访问 LiteLLM（模型调用）、DNS 和外部 HTTPS 服务，不能访问集群内其他服务。

### 重要提示

Pod **必须** 包含 `app: hermes-sandbox` 标签才会被 NetworkPolicy 选中。如果遗漏此标签，Pod 将不受网络限制。

## 费用管控

### 查看租户用量

通过 LiteLLM 管理 API 查看（需要 Master Key）：

```bash
# 获取 Master Key
MASTER_KEY=$(kubectl get secret litellm-masterkey -n litellm \
  -o jsonpath='{.data.masterkey}' | base64 -d)

# 查看所有 Key 的用量
kubectl run -n litellm check-keys --rm -i --restart=Never \
  --image=curlimages/curl -- \
  curl -s http://litellm:4000/key/info \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key": "TENANT_API_KEY_HERE"}'
```

### 预算耗尽时的行为

当租户的 API Key 达到 `max_budget` 上限时，LiteLLM 返回 HTTP 400：

```json
{
  "error": {
    "message": "Budget has been exceeded! Current cost: 10.05, Max budget: 10.0",
    "type": "budget_exceeded",
    "code": "400"
  }
}
```

Hermes Agent 会收到错误并通知用户，但不影响其他租户。

### 调整预算

修改 `terraform.tfvars` 中的 `max_budget` 值后重新 apply：

```bash
terraform apply -var="name=my-hermes"
```

> 注意：`terraform_data` 资源会重新创建 Key。如果需要不重建 Key 就调整限额，可直接调用 LiteLLM API：

```bash
kubectl run -n litellm update-key --rm -i --restart=Never \
  --image=curlimages/curl -- \
  curl -s -X POST http://litellm:4000/key/update \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "key": "TENANT_API_KEY",
    "max_budget": 50,
    "rpm_limit": 60
  }'
```

## 运维操作

### 添加新租户

1. 在 `terraform.tfvars` 中新增条目：

```hcl
hermes_tenants = {
  # 已有租户...
  team-gamma = {
    platform   = "feishu"
    max_budget = 15
    rpm_limit  = 20
  }
}
```

2. Apply：

```bash
terraform apply -var="name=my-hermes"
```

3. 部署沙箱 Pod（参考上面的 YAML 模板，替换 tenant 名称和平台凭据）。

### 移除租户

1. 删除沙箱 Pod 和相关资源：

```bash
kubectl delete pod hermes-team-gamma-sandbox -n hermes
kubectl delete pvc hermes-team-gamma-data -n hermes
kubectl delete secret hermes-team-gamma-secrets -n hermes
```

2. 从 `terraform.tfvars` 中移除该租户条目。

3. Apply：

```bash
terraform apply -var="name=my-hermes"
```

Terraform 会自动清理 Secret、ConfigMap 和 LiteLLM Key。

### 查看所有租户状态

```bash
# 所有租户 Pod
kubectl get pods -n hermes -l app=hermes-sandbox -L tenant

# 所有租户 Secret
kubectl get secrets -n hermes -l app=hermes-sandbox -L tenant

# 网络策略
kubectl get networkpolicy -n hermes
```

输出示例：

```
NAME                          READY   STATUS    TENANT
hermes-team-alpha-sandbox     1/1     Running   team-alpha
hermes-team-beta-sandbox      1/1     Running   team-beta
hermes-team-gamma-sandbox     1/1     Running   team-gamma
```

### 验证网络隔离

从 team-alpha 尝试访问 team-beta：

```bash
# 应该失败（被 NetworkPolicy 拒绝）
kubectl exec -n hermes hermes-team-alpha-sandbox -- \
  curl -s --connect-timeout 3 http://hermes-team-beta-sandbox.hermes:8642/health

# 应该成功（LiteLLM 出站允许）
kubectl exec -n hermes hermes-team-alpha-sandbox -- \
  curl -s --connect-timeout 3 http://litellm.litellm.svc.cluster.local:4000/health
```

## 典型场景配置

### 场景 1：开发团队（低限额试用）

```hcl
dev-team = {
  platform       = "slack"
  max_budget     = 5
  rpm_limit      = 10
  tpm_limit      = 30000
  budget_duration = "7d"
}
```

### 场景 2：生产团队（高吞吐）

```hcl
prod-team = {
  platform   = "feishu"
  max_budget = 100
  rpm_limit  = 60
  tpm_limit  = 500000
  models     = ["claude-opus-4-6"]
}
```

### 场景 3：多模型访问

如果 LiteLLM 配置了多个模型（需同步修改 `litellm.tf` 的 `model_list`）：

```hcl
ml-team = {
  platform   = "slack"
  max_budget = 50
  models     = ["claude-opus-4-6", "claude-sonnet-4-6"]
  rpm_limit  = 40
}
```

## 监控

Grafana 仪表盘可以按租户维度查看用量（LiteLLM 已开启 Prometheus callback）：

```bash
# 端口转发 Grafana
kubectl port-forward -n monitoring svc/grafana 3000:80

# 获取 admin 密码
terraform output -raw grafana_admin_password
```

LiteLLM 导出的关键 Prometheus 指标：

| 指标 | 说明 |
|------|------|
| `litellm_requests_total` | 总请求数 |
| `litellm_spend_metric` | 费用指标 |
| `litellm_request_total_latency_metric` | 请求延迟 |

可在 Grafana 中按 `api_key` label 分组，实现 per-tenant 监控面板。
