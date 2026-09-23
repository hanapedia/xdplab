variable "libvirt_uri" {
  description = "libvirt connection URI"
  type        = string
  default     = "qemu:///system"
}

variable "qemu_group_gid" {
  description = "GID of the group QEMU can access disk images through (this host's `kvm` group, via `getent group kvm` -- libvirt-qemu is a member). Confirm on a different machine before reusing."
  type        = string
  default     = "991"
}

variable "storage_pool_name" {
  description = "Name of the dedicated libvirt storage pool this config creates and destroys for VM disks"
  type        = string
  default     = "xdplab"
}

variable "storage_pool_path" {
  description = "Host directory backing the storage pool. Wiped on `tofu destroy` (dir pools delete their backing storage by default) — kept separate from libvirt's own `default` pool so destroy can't touch anything else."
  type        = string
  default     = "/var/lib/libvirt/images/xdplab"
}

variable "install_iso_path" {
  description = "Path to the Talos installer ISO (host path, not a Terraform-managed volume) — must be built with talos.config=metal-iso baked in via talos/scripts/build-installer-iso.sh, shared by every VM"
  type        = string
}

variable "node_config_iso_paths" {
  description = "Per-VM metal-iso config volume paths, keyed like var.vms — each is the full rendered machine config (talos/terraform's render.tf output, wrapped by talos/scripts/build-node-config-iso.sh). Talos requires a complete valid config (cluster CA present) to accept it at all, so this can't be a shared/partial config across VMs -- each node gets its own, and self-installs/self-configures from it on first boot (see talos/terraform/README notes in DESIGN.md §3)."
  type        = map(string)
}

variable "vm_disk_capacity_gib" {
  description = "Per-VM primary disk capacity, in GiB"
  type        = number
  default     = 40
}

variable "vm_memory_mib" {
  description = "Per-VM memory, in MiB"
  type        = number
  default     = 4096
}

variable "vm_vcpu" {
  description = "Per-VM vCPU count"
  type        = number
  default     = 2
}

variable "ovmf_code_path" {
  description = "Path to the OVMF UEFI firmware (read-only pflash), from the `ovmf` package. Plain 4M variant — no secure boot, so no enrolled-cert (.ms/.snakeoil) fuss for a disposable lab."
  type        = string
  default     = "/usr/share/OVMF/OVMF_CODE_4M.fd"
}

variable "ovmf_vars_template_path" {
  description = "Path to the OVMF UEFI vars template libvirt copies per-VM on first boot, from the `ovmf` package"
  type        = string
  default     = "/usr/share/OVMF/OVMF_VARS_4M.fd"
}

variable "vms" {
  description = <<-EOT
    One entry per Talos VM. pci_* pins the VFIO hostdev passthrough to a specific
    physical NIC port (§1.1 DESIGN.md). Defaults are r9600's 0000:04:00.0/0000:04:00.1
    (enp4s0f0/enp4s0f1), per vfio_setup.md.
  EOT
  type = map(object({
    pci_domain   = number
    pci_bus      = number
    pci_slot     = number
    pci_function = number
  }))
  default = {
    control-plane = { pci_domain = 0, pci_bus = 4, pci_slot = 0, pci_function = 0 } # enp4s0f0 -> 10.10.0.2
    worker        = { pci_domain = 0, pci_bus = 4, pci_slot = 0, pci_function = 1 } # enp4s0f1 -> 10.10.1.2
  }
}
