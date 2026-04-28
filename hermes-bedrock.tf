# IAM Role for Hermes Agent pods to access Bedrock directly (optional, alternative to LiteLLM)
data "aws_iam_policy_document" "hermes_bedrock" {
  statement {
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "hermes_bedrock" {
  name   = "${local.name}-hermes-bedrock"
  policy = data.aws_iam_policy_document.hermes_bedrock.json
  tags   = local.tags
}

module "hermes_bedrock_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name_prefix = "${local.name}-hermes-bedrock-"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${local.hermes_namespace}:hermes-sandbox"]
    }
  }

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "hermes_bedrock" {
  role       = module.hermes_bedrock_irsa.iam_role_name
  policy_arn = aws_iam_policy.hermes_bedrock.arn
}

resource "kubernetes_service_account_v1" "hermes_sandbox" {
  metadata {
    name      = "hermes-sandbox"
    namespace = local.hermes_namespace
    annotations = {
      "eks.amazonaws.com/role-arn" = module.hermes_bedrock_irsa.iam_role_arn
    }
  }

  depends_on = [kubernetes_namespace_v1.hermes]
}
