output "vm_uuids" {
  description = "libvirt domain UUID per VM"
  value       = { for k, v in libvirt_domain.vm : k => v.uuid }
}

output "vm_disk_paths" {
  description = "Host path of each VM's primary qcow2 disk"
  value       = { for k, v in libvirt_volume.vm_disk : k => v.path }
}
