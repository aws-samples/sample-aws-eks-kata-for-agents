resource "helm_release" "kata_deploy" {
  name       = "kata-deploy"
  repository = "oci://ghcr.io/kata-containers/kata-deploy-charts"
  chart      = "kata-deploy"
  namespace  = kubernetes_namespace_v1.kata_system.metadata[0].name
  version    = "3.27.0"

  create_namespace = false
  wait             = false

  values = [
    yamlencode({
      nodeSelector = {
        "workload-type" = "kata"
      }
      tolerations = [{
        key      = "kata"
        operator = "Equal"
        value    = "true"
        effect   = "NoSchedule"
      }]
      image = {
        reference = "quay.io/kata-containers/kata-deploy"
      }
      shims = {
        disableAll = true
        qemu = {
          enabled = true
        }
        clh = {
          enabled = true
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace_v1.kata_system,
    kubectl_manifest.kata_node_pool,
  ]
}
