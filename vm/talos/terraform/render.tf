# Renders each node's full machine config to a local file instead of
# applying it live (talos_machine_configuration_apply) -- our hardware can't
# reach a live-applicable maintenance-mode node in the first place: ixgbe
# needs a config to load, but a config that's valid enough for Talos to
# accept (cluster CA present) makes Talos perform a full unattended install
# right there instead of waiting for a live apply. So these rendered files
# are fed into the metal-iso config volume instead (talos/scripts/build-node-config-iso.sh,
# task talos:iso:config), and the node self-installs/self-configures on
# first boot. talos_machine_bootstrap/talos_cluster_kubeconfig (bootstrap.tf,
# kubeconfig.tf) then target the resulting already-configured, reachable node.
resource "local_sensitive_file" "control_plane" {
  content         = data.talos_machine_configuration.control_plane.machine_configuration
  filename        = "${path.module}/rendered/control-plane.yaml"
  file_permission = "0600"
}

resource "local_sensitive_file" "worker" {
  content         = data.talos_machine_configuration.worker.machine_configuration
  filename        = "${path.module}/rendered/worker.yaml"
  file_permission = "0600"
}
