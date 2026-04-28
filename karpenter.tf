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

# EC2NodeClass for Kata nodes (nested KVM on c8i/m8i)
resource "kubectl_manifest" "kata_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "kata-nested-kvm"
    }
    spec = {
      role            = module.karpenter.node_iam_role_name
      amiSelectorTerms = [{
        alias = "al2023@latest"
      }]
      subnetSelectorTerms = [{
        tags = {
          "karpenter.sh/discovery" = local.name
        }
      }]
      securityGroupSelectorTerms = [{
        tags = {
          "karpenter.sh/discovery" = local.name
        }
      }]
      blockDeviceMappings = [{
        deviceName = "/dev/xvda"
        ebs = {
          volumeSize          = "100Gi"
          volumeType          = "gp3"
          encrypted           = true
          deleteOnTermination = true
        }
      }]
      userData = <<-USERDATA
        #!/bin/bash
        set -ex

        # Verify nested KVM is available (c8i/m8i expose /dev/kvm)
        if [[ ! -e /dev/kvm ]]; then
          echo "WARNING: /dev/kvm not found — nested KVM not supported on this instance type"
        fi
      USERDATA

      tags = local.tags
    }
  })

  depends_on = [helm_release.karpenter]
}

# NodePool for Kata workloads (nested KVM on c8i/m8i)
resource "kubectl_manifest" "kata_node_pool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "kata-nested-kvm"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            "workload-type"                        = "kata"
            "katacontainers.io/kata-runtime"        = "true"
          }
        }
        spec = {
          requirements = [
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["on-demand"]
            },
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = var.kata_instance_types
            }
          ]
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "kata-nested-kvm"
          }
          taints = [{
            key    = "kata"
            value  = "true"
            effect = "NoSchedule"
          }]
        }
      }
      limits = {
        cpu    = "64"
        memory = "256Gi"
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
      }
    }
  })

  depends_on = [kubectl_manifest.kata_node_class]
}
