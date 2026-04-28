# Hermes Agent ConfigMap (base config, shared across sandboxes)
resource "kubernetes_config_map_v1" "hermes_base_config" {
  metadata {
    name      = "hermes-base-config"
    namespace = local.hermes_namespace
  }

  data = {
    "config.yaml" = yamlencode({
      model = {
        default   = var.hermes_model_default
        provider  = "custom"
        base_url  = "http://litellm.litellm.svc.cluster.local:4000"
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
      You are an enterprise AI assistant running in a secure sandbox environment.
      You can execute code, analyze data, and manage files.
      Always follow security best practices and avoid destructive operations.
    SOUL
  }

  depends_on = [kubernetes_namespace_v1.hermes]
}

# Default deny all ingress between sandbox pods — each tenant is isolated
resource "kubernetes_network_policy_v1" "hermes_deny_inter_pod" {
  metadata {
    name      = "deny-inter-pod-ingress"
    namespace = local.hermes_namespace
  }

  spec {
    pod_selector {
      match_labels = {
        app = "hermes-sandbox"
      }
    }

    policy_types = ["Ingress"]

    # No ingress rules = deny all ingress from other pods
    # (k8s services like kubelet health checks still work)
  }

  depends_on = [kubernetes_namespace_v1.hermes]
}

# Egress policy for sandbox pods — only LiteLLM, DNS, and HTTPS
resource "kubernetes_network_policy_v1" "hermes_sandbox_egress" {
  metadata {
    name      = "hermes-sandbox-egress"
    namespace = local.hermes_namespace
  }

  spec {
    pod_selector {
      match_labels = {
        app = "hermes-sandbox"
      }
    }

    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            name = "litellm"
          }
        }
      }
      ports {
        port     = 4000
        protocol = "TCP"
      }
    }

    egress {
      to {
        namespace_selector {}
      }
      ports {
        port     = 53
        protocol = "UDP"
      }
      ports {
        port     = 53
        protocol = "TCP"
      }
    }

    egress {
      to {
        ip_block {
          cidr = "0.0.0.0/0"
        }
      }
      ports {
        port     = 443
        protocol = "TCP"
      }
      ports {
        port     = 80
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.hermes]
}
