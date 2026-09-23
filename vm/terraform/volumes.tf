resource "libvirt_volume" "vm_disk" {
  for_each = var.vms

  name     = "xdplab-${each.key}.qcow2"
  pool     = libvirt_pool.xdplab.name
  capacity = var.vm_disk_capacity_gib * 1024 * 1024 * 1024

  target = {
    format = {
      type = "qcow2"
    }
    # libvirt's dynamic-ownership chown-on-start doesn't reach volumes
    # referenced by pool+name (only direct file-path disks) here, so QEMU
    # (runs as libvirt-qemu, a member of the kvm group) can't open a
    # root:root 0600 file. Grant the kvm group access explicitly instead.
    permissions = {
      group = var.qemu_group_gid
      mode  = "0660"
    }
  }
}
