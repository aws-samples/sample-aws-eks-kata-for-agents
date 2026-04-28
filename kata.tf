# Kata system namespace
resource "kubernetes_namespace_v1" "kata_system" {
  metadata {
    name = local.kata_namespace
    labels = {
      name = local.kata_namespace
    }
  }

  depends_on = [module.eks]
}

# Hermes namespace
resource "kubernetes_namespace_v1" "hermes" {
  metadata {
    name = local.hermes_namespace
    labels = {
      name = local.hermes_namespace
    }
  }

  depends_on = [module.eks]
}
