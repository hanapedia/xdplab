# One domain per Talos VM (DESIGN.md §2): q35 + UEFI/OVMF, host-passthrough CPU,
# a single VFIO PCI hostdev per VM (the physical NIC port), no virtual NIC.
resource "libvirt_domain" "vm" {
  for_each = var.vms

  name    = "xdplab-${each.key}"
  type    = "kvm"
  memory  = var.vm_memory_mib
  vcpu    = var.vm_vcpu
  running = true

  memory_unit = "MiB"

  cpu = {
    mode = "host-passthrough"
  }

  # UEFI requires ACPI on x86_64 (libvirt rejects the domain otherwise).
  features = {
    acpi = true
  }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"

    firmware        = "efi"
    loader          = var.ovmf_code_path
    loader_readonly = "yes"
    loader_type     = "pflash"
    nv_ram = {
      nv_ram   = "/var/lib/libvirt/qemu/nvram/xdplab-${each.key}_VARS.fd"
      template = var.ovmf_vars_template_path
    }

    # cdrom first for install; harmless once Talos owns the disk, since the
    # firmware falls through to hd when the attached ISO isn't a valid boot medium.
    boot_devices = [{ dev = "cdrom" }, { dev = "hd" }]
  }

  devices = {
    disks = [
      {
        device = "disk"
        driver = {
          name = "qemu"
          type = "qcow2"
        }
        source = {
          file = {
            file = libvirt_volume.vm_disk[each.key].path
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      },
      {
        device    = "cdrom"
        read_only = true
        driver = {
          name = "qemu"
          type = "raw"
        }
        source = {
          file = {
            file = var.install_iso_path
          }
        }
        target = {
          dev = "sda"
          bus = "sata"
        }
      },
      {
        # This node's full machine config (talos/terraform's render.tf),
        # delivered via talos.config=metal-iso -- the installer ISO's baked-in
        # kernel arg makes Talos read this at boot, no network needed. Not a
        # boot device, just needs to be a visible block device. Per-node, not
        # shared -- see var.node_config_iso_paths.
        device    = "cdrom"
        read_only = true
        driver = {
          name = "qemu"
          type = "raw"
        }
        source = {
          file = {
            file = var.node_config_iso_paths[each.key]
          }
        }
        target = {
          dev = "sdb"
          bus = "sata"
        }
      }
    ]

    # Debug visibility only -- QEMU's own `-nodefaults` (always set by this
    # provider) means no serial port exists at all otherwise, and `virsh
    # console`/boot logs would be silent.
    serials = [
      {
        source = { file = { path = "/var/log/libvirt/qemu/xdplab-${each.key}-console.log" } }
        target = { port = 0 }
      }
    ]
    consoles = [
      {
        source = { file = { path = "/var/log/libvirt/qemu/xdplab-${each.key}-console.log" } }
        target = { type = "serial", port = 0 }
      }
    ]

    # Debug visibility only -- Talos's stock ISO renders its boot console to
    # the default video framebuffer (tty0), not serial, so this is what
    # `virsh screenshot` actually needs to show anything.
    videos = [
      { model = { type = "vga" } }
    ]
    graphics = [
      { vnc = { listen = "127.0.0.1", auto_port = true } }
    ]

    hostdevs = [
      {
        managed = true
        subsys_pci = {
          source = {
            address = {
              domain   = each.value.pci_domain
              bus      = each.value.pci_bus
              slot     = each.value.pci_slot
              function = each.value.pci_function
            }
          }
        }
      }
    ]
  }
}
