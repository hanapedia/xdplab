locals {
  cluster_endpoint = "https://${var.control_plane_ip}:6443"

  # Shared by every node's config, regardless of role. Talos 1.14 rejects
  # mixing a new per-document kind with the legacy monolithic field it
  # supersedes (metal-iso's own config.AcquireController validation, e.g.
  # "UnattendedInstallConfig config is incompatible with v1alpha1 config
  # (.machine.install)") -- so once a new-style document is patched here,
  # its legacy field must NOT also be touched, by this patch or any other.
  #
  # CNI stays Talos's default (flannel) for now, not yet Calico/Cilium BGP
  # mode per DESIGN.md §4 (final choice not made) -- disabling it requires
  # patching/removing the auto-generated KubeFlannelCNIConfig document, not
  # yet done here.
  common_config_patches = [
    file("${path.module}/../patches/kernel-modules.yaml"),
    # Talos 1.14's separate unattended-install document -- what a metal-iso
    # boot actually reads to install itself. Its default disk selector
    # ("/dev/sda") never matches these VMs' virtio disk, so without this
    # override the node finds nothing to install to and never progresses
    # (kernel.modules still loads -- an earlier, independent stage -- but
    # nothing else committed by install ever takes effect, including this
    # same config's own .machine.time.servers). Both fields MUST be in one
    # patch: two config_patches entries each declaring their own
    # `kind: UnattendedInstallConfig` document don't deep-merge with each
    # other -- the later one replaces the whole document. Pulled through
    # the regmirror factory.talos.dev cache, same as every other image,
    # since the VMs have no route to the public internet.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "UnattendedInstallConfig"
      installer = {
        image = var.install_image
      }
      provisioning = {
        diskSelector = {
          match = "disk.dev_path == \"/dev/vda\""
        }
      }
    }),
  ]
}
