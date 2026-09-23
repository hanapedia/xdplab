# Dedicated, disposable pool for this lab's VM disks — `dir` pools delete their
# backing storage on destroy by default, so `tofu destroy` wipes it along with
# the domains/volumes. Kept separate from libvirt's own `default` pool.
resource "libvirt_pool" "xdplab" {
  name = var.storage_pool_name
  type = "dir"

  target = {
    path = var.storage_pool_path
  }
}
