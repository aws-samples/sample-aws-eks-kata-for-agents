module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.24"

  cluster_name = module.eks.cluster_name

  enable_pod_identity             = true
  create_pod_identity_association = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

resource "aws_iam_policy" "karpenter_list_instance_profiles" {
  name = "${local.name}-karpenter-list-instance-profiles"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "iam:ListInstanceProfiles"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_list_instance_profiles" {
  role       = module.karpenter.iam_role_name
  policy_arn = aws_iam_policy.karpenter_list_instance_profiles.arn
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.7.4"

  values = [
    yamlencode({
      settings = {
        clusterName     = module.eks.cluster_name
        clusterEndpoint = module.eks.cluster_endpoint
        interruptionQueue = module.karpenter.queue_name
      }
      tolerations = [
        {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
        },
        {
          key      = "karpenter.sh/controller"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      ]
    })
  ]

  depends_on = [
    module.karpenter,
    module.eks_blueprints_addons,
  ]
}

