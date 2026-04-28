variable "name" {
  description = "Name for the VPC and EKS cluster"
  type        = string
  default     = "hermes-kata-eks"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "eks_cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.1.0.0/16"
}

variable "kata_hypervisor" {
  description = "Kata Containers hypervisor to use: qemu, clh, or fc"
  type        = string
  default     = "clh"

  validation {
    condition     = contains(["qemu", "clh", "fc"], var.kata_hypervisor)
    error_message = "kata_hypervisor must be one of: qemu, clh, or fc"
  }
}

variable "kata_instance_types" {
  description = "Instance types for Kata nodes (must support nested KVM: c8i, m8i, r8i families)"
  type        = list(string)
  default     = ["c8i.2xlarge", "c8i.4xlarge", "m8i.2xlarge", "m8i.4xlarge"]
}

variable "is_china_region" {
  description = "Whether the deployment targets AWS China region"
  type        = bool
  default     = null
}

variable "access_entries" {
  description = "Map of access entries for the EKS cluster"
  type        = any
  default     = {}
}

variable "kms_key_admin_roles" {
  description = "List of IAM role ARNs that should be KMS key administrators"
  type        = list(string)
  default     = []
}

variable "hermes_agent_image" {
  description = "Docker image for Hermes Agent"
  type        = string
  default     = "nousresearch/hermes-agent:latest"
}

variable "hermes_model_default" {
  description = "Default model for Hermes Agent (via LiteLLM)"
  type        = string
  default     = "claude-opus-4-6"
}

variable "hermes_tenants" {
  description = "Map of tenant name → config. Each tenant gets an isolated sandbox with its own LiteLLM API key."
  type = map(object({
    platform       = string
    max_budget     = optional(number, 10)
    rpm_limit      = optional(number, 30)
    tpm_limit      = optional(number, 100000)
    models         = optional(list(string), ["claude-opus-4-6"])
    budget_duration = optional(string, "30d")
  }))
  default = {}
}
