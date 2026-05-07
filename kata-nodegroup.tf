# Kata node group supports two modes:
# - "nested-kvm": c8i/m8i/r8i instances with NestedVirtualization=enabled (default)
# - "bare-metal": *.metal instances with native KVM (no nested virt needed)
#
# For nested-kvm mode, the launch template must be pre-created via AWS CLI
# (install.sh handles this) because neither Terraform AWS provider 5.x nor
# CloudFormation supports CpuOptions.NestedVirtualization yet.

# Kata nodes only get the EKS cluster primary SG (not the node SG) because they
# use an external launch template. This rule allows Kata nodes to reach core nodes
# (e.g. LiteLLM on hostPort) by permitting cluster primary SG → node SG traffic.
resource "aws_security_group_rule" "kata_to_node_all_traffic" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = module.eks.cluster_primary_security_group_id
  description              = "Allow Kata nodes (cluster primary SG) to access core nodes"
}

locals {
  kata_use_nested_kvm = var.kata_node_mode == "nested-kvm"
  kata_lt_name        = "${local.name}-kata-${var.kata_node_mode}"
}

data "aws_launch_template" "kata_nested_kvm" {
  count = local.kata_use_nested_kvm ? 1 : 0
  name  = local.kata_lt_name
}

# Launch template for bare-metal instances (no nested virt needed, native /dev/kvm)
resource "aws_launch_template" "kata_bare_metal" {
  count = local.kata_use_nested_kvm ? 0 : 1

  name_prefix = "${local.name}-kata-bare-metal-"
  description = "Launch template for Kata bare-metal nodes"

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.tags, {
      Name = "${local.name}-kata-bare-metal"
    })
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

# EKS Managed Node Group for Kata workloads
module "eks_kata_node_group" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "~> 20.24"

  name            = "kata-${var.kata_node_mode}"
  cluster_name    = module.eks.cluster_name
  cluster_version = var.eks_cluster_version

  cluster_service_cidr = module.eks.cluster_service_cidr

  subnet_ids = module.vpc.private_subnets

  cluster_primary_security_group_id = module.eks.cluster_primary_security_group_id
  vpc_security_group_ids            = [module.eks.node_security_group_id]

  min_size     = var.kata_node_min_size
  max_size     = var.kata_node_max_size
  desired_size = var.kata_node_desired_size

  instance_types = var.kata_instance_types
  ami_type       = "AL2023_x86_64_STANDARD"

  create_launch_template     = false
  use_custom_launch_template = true
  launch_template_id = (
    local.kata_use_nested_kvm
    ? data.aws_launch_template.kata_nested_kvm[0].id
    : aws_launch_template.kata_bare_metal[0].id
  )
  launch_template_version = (
    local.kata_use_nested_kvm
    ? tostring(data.aws_launch_template.kata_nested_kvm[0].latest_version)
    : tostring(aws_launch_template.kata_bare_metal[0].latest_version)
  )

  labels = {
    "workload-type"                  = "kata"
    "katacontainers.io/kata-runtime" = "true"
  }

  taints = {
    kata = {
      key    = "kata"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }

  iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}
