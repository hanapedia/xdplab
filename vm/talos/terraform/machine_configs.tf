data "talos_machine_configuration" "control_plane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  machine_type       = "controlplane"
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
  config_patches = concat(local.common_config_patches, [
    # HostnameConfig is its own document (Talos 1.14) -- setting the legacy
    # .machine.network.hostname instead conflicts with it (see locals.tf).
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = "control-plane"
    }),
    yamlencode({
      machine = {
        time = {
          servers = [var.control_plane_gateway]
        }
        registries = {
          mirrors = {
            "factory.talos.dev" = {
              endpoints = ["http://${var.control_plane_gateway}:${var.regmirror_factory_port}"]
            }
            "registry.k8s.io" = {
              endpoints = ["http://${var.control_plane_gateway}:${var.regmirror_k8s_port}"]
            }
            "ghcr.io" = {
              endpoints = ["http://${var.control_plane_gateway}:${var.regmirror_ghcr_port}"]
            }
          }
        }
      }
    })
  ])
}

data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  machine_type       = "worker"
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
  config_patches = concat(local.common_config_patches, [
    # HostnameConfig is its own document (Talos 1.14) -- setting the legacy
    # .machine.network.hostname instead conflicts with it (see locals.tf).
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = "worker"
    }),
    yamlencode({
      machine = {
        time = {
          servers = [var.worker_gateway]
        }
        registries = {
          mirrors = {
            "factory.talos.dev" = {
              endpoints = ["http://${var.worker_gateway}:${var.regmirror_factory_port}"]
            }
            "registry.k8s.io" = {
              endpoints = ["http://${var.worker_gateway}:${var.regmirror_k8s_port}"]
            }
            "ghcr.io" = {
              endpoints = ["http://${var.worker_gateway}:${var.regmirror_ghcr_port}"]
            }
          }
        }
      }
    })
  ])
}
