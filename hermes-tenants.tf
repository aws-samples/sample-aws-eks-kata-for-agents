# Per-tenant multi-tenancy: network isolation + LiteLLM API key provisioning
#
# Each tenant gets:
#   1. An isolated LiteLLM API key with budget, RPM/TPM limits, model ACL
#   2. A ConfigMap with tenant-specific Hermes config
#   3. Pod label "tenant=<name>" for NetworkPolicy enforcement
#
# Usage in variables.tf:
#   hermes_tenants = {
#     team-alpha = { platform = "slack",    max_budget = 20 }
#     team-beta  = { platform = "telegram", max_budget = 5, rpm_limit = 10 }
#   }

# Generate a per-tenant LiteLLM API key via the LiteLLM admin API.
# The key is created by running curl inside the cluster (to reach the ClusterIP)
# and captured as a Terraform output.
resource "terraform_data" "tenant_litellm_key" {
  for_each = var.hermes_tenants

  input = {
    tenant          = each.key
    models          = jsonencode(each.value.models)
    max_budget      = each.value.max_budget
    rpm_limit       = each.value.rpm_limit
    tpm_limit       = each.value.tpm_limit
    budget_duration = each.value.budget_duration
    master_key      = local.litellm_master_key
  }

  provisioner "local-exec" {
    command = <<-CMD
      KEY=$(kubectl run -n litellm "gen-key-${each.key}" --rm -i \
        --restart=Never --image=curlimages/curl -- \
        curl -sf -X POST http://litellm:4000/key/generate \
        -H "Authorization: Bearer ${local.litellm_master_key}" \
        -H "Content-Type: application/json" \
        -d '{
          "key_alias": "tenant-${each.key}",
          "models": ${jsonencode(each.value.models)},
          "max_budget": ${each.value.max_budget},
          "rpm_limit": ${each.value.rpm_limit},
          "tpm_limit": ${each.value.tpm_limit},
          "budget_duration": "${each.value.budget_duration}",
          "metadata": {"tenant": "${each.key}"}
        }' 2>/dev/null | grep -o '"key":"[^"]*"' | cut -d'"' -f4)

      if [ -z "$KEY" ]; then
        echo "ERROR: Failed to generate LiteLLM key for tenant ${each.key}"
        exit 1
      fi

      # Store the key in a Kubernetes Secret
      kubectl create secret generic "hermes-${each.key}-litellm" \
        -n hermes \
        --from-literal=api_key="$KEY" \
        --from-literal=tenant="${each.key}" \
        --dry-run=client -o yaml | kubectl apply -f -

      # Label it
      kubectl label secret "hermes-${each.key}-litellm" -n hermes \
        app=hermes-sandbox tenant=${each.key} --overwrite

      echo "Tenant ${each.key}: API key provisioned ($$KEY)"
    CMD
  }

  depends_on = [helm_release.litellm, kubernetes_namespace_v1.hermes]
}

# Per-tenant ConfigMap
resource "kubernetes_config_map_v1" "tenant_config" {
  for_each = var.hermes_tenants

  metadata {
    name      = "hermes-${each.key}-config"
    namespace = local.hermes_namespace
    labels = {
      app    = "hermes-sandbox"
      tenant = each.key
    }
  }

  data = {
    "config.yaml" = yamlencode({
      model = {
        default  = each.value.models[0]
        provider = "custom"
        base_url = "http://litellm.litellm.svc.cluster.local:4000"
      }
      terminal = {
        backend = "local"
        timeout = 180
      }
      compression = {
        enabled   = true
        threshold = 0.50
      }
    })

    "SOUL.md" = <<-SOUL
      You are an enterprise AI assistant for tenant "${each.key}".
      You can execute code, analyze data, and manage files.
      Always follow security best practices.
    SOUL
  }

  depends_on = [kubernetes_namespace_v1.hermes]
}
