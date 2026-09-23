output "kubeconfig" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}

output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}

output "cluster_endpoint" {
  value = local.cluster_endpoint
}

output "rendered_config_paths" {
  description = "Local paths of the rendered per-node machine configs (render.tf) -- feed into talos:iso:config"
  value = {
    control-plane = local_sensitive_file.control_plane.filename
    worker        = local_sensitive_file.worker.filename
  }
}
