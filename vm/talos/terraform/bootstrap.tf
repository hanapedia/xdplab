# No Terraform-tracked dependency on the node actually being configured --
# that happens out-of-band via the rendered config + metal-iso (render.tf).
# Run this only after the VMs have booted off that media and installed
# themselves (task vm:setup, after task talos:iso:config); it'll fail with
# a connection error otherwise, same as talosctl bootstrap would.
resource "talos_machine_bootstrap" "this" {
  node                 = var.control_plane_ip
  client_configuration = talos_machine_secrets.this.client_configuration
}
