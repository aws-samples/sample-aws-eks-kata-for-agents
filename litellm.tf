# LiteLLM namespace
resource "kubernetes_namespace_v1" "litellm" {
  metadata {
    name = "litellm"
    labels = {
      name = "litellm"
    }
  }

  depends_on = [module.eks]
}

# LiteLLM master key
resource "random_password" "litellm_master_key" {
  length  = 32
  special = false
}

locals {
  litellm_master_key = "sk-${random_password.litellm_master_key.result}"
}

# IAM Policy for Bedrock access
resource "aws_iam_policy" "litellm_bedrock" {
  name        = "${local.name}-litellm-bedrock"
  description = "Allow LiteLLM to invoke Bedrock models"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = "*"
      }
    ]
  })

  tags = local.tags
}

# IAM Role for LiteLLM Pod Identity
resource "aws_iam_role" "litellm_pod_identity" {
  name = "${local.name}-litellm-pod-identity"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = local.pod_identity_principal
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "litellm_bedrock" {
  role       = aws_iam_role.litellm_pod_identity.name
  policy_arn = aws_iam_policy.litellm_bedrock.arn
}

# Service Account for LiteLLM
resource "kubernetes_service_account_v1" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace_v1.litellm.metadata[0].name
  }
}

# Pod Identity Association
resource "aws_eks_pod_identity_association" "litellm" {
  cluster_name    = module.eks.cluster_name
  namespace       = kubernetes_namespace_v1.litellm.metadata[0].name
  service_account = kubernetes_service_account_v1.litellm.metadata[0].name
  role_arn        = aws_iam_role.litellm_pod_identity.arn

  depends_on = [kubernetes_service_account_v1.litellm]
}

# LiteLLM Helm release
resource "helm_release" "litellm" {
  name       = "litellm"
  repository = "oci://ghcr.io/berriai"
  chart      = "litellm-helm"
  namespace  = kubernetes_namespace_v1.litellm.metadata[0].name

  values = [
    yamlencode({
      masterkey = local.litellm_master_key

      serviceAccount = {
        create = false
        name   = kubernetes_service_account_v1.litellm.metadata[0].name
      }

      global = {
        security = {
          allowInsecureImages = true
        }
      }

      db = {
        useExisting   = false
        deployStandalone = true
        image = {
          repository = "public.ecr.aws/docker/library/postgres"
          tag        = "16"
        }
      }

      proxy_config = {
        model_list = [
          {
            model_name = "claude-opus-4-6"
            litellm_params = {
              model           = "bedrock/us.anthropic.claude-opus-4-6-v1"
              aws_region_name = "us-east-1"
            }
          }
        ]
        litellm_settings = {
          modify_params = true
          callbacks     = ["prometheus"]
        }
      }

      service = {
        type = "ClusterIP"
      }
    })
  ]

  depends_on = [
    aws_eks_pod_identity_association.litellm,
    kubernetes_storage_class_v1.ebs_csi_default
  ]
}
