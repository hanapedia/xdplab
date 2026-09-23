variable "cluster_name" {
  description = "Talos/Kubernetes cluster name"
  type        = string
  default     = "xdplab"
}

variable "talos_version" {
  description = "Talos version contract used to generate machine configs (schema/defaults pin, not the installed OS version -- see talos_machine_configuration docs). Keep in sync with the actual running Talos version (talos/scripts/build-installer-iso.sh)."
  type        = string
  default     = "v1.14"
}

variable "install_image" {
  description = "Talos installer image referenced by machine.install.image -- the Image Factory metal-installer for talos_version, empty schematic (no system extensions; ixgbe is loaded via .machine.kernel.modules instead, not an extension). Pulled through the regmirror factory.talos.dev cache, not fetched directly -- the VMs have no route to the public internet."
  type        = string
  default     = "factory.talos.dev/metal-installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.14.1"
}

variable "kubernetes_version" {
  description = "Kubernetes version baked into the generated config (bootstrap/scale-up only -- upgrading a running cluster is a separate, later concern)"
  type        = string
  default     = "v1.35.0"
}

variable "control_plane_ip" {
  description = "control-plane VM's DHCP-reserved IP (DESIGN.md addressing table / dnsmasq.conf)"
  type        = string
  default     = "10.10.0.2"
}

variable "worker_ip" {
  description = "worker VM's DHCP-reserved IP (DESIGN.md addressing table / dnsmasq.conf)"
  type        = string
  default     = "10.10.1.2"
}

variable "control_plane_gateway" {
  description = "r5500's address on control-plane's /30 (also its NTP server -- see r5500's /etc/chrony/conf.d/xdplab-ntp-server.conf. The VMs have no route to the public internet, and Talos won't boot past early init without successful time sync)"
  type        = string
  default     = "10.10.0.1"
}

variable "worker_gateway" {
  description = "r5500's address on worker's /30 (also its NTP server -- see control_plane_gateway)"
  type        = string
  default     = "10.10.1.1"
}

variable "regmirror_factory_port" {
  description = "Port r5500's factory.talos.dev pull-through cache listens on (regmirror/mirrors.conf)"
  type        = string
  default     = "5000"
}

variable "regmirror_k8s_port" {
  description = "Port r5500's registry.k8s.io pull-through cache listens on (regmirror/mirrors.conf)"
  type        = string
  default     = "5001"
}

variable "regmirror_ghcr_port" {
  description = "Port r5500's ghcr.io pull-through cache listens on (regmirror/mirrors.conf) -- Talos vendors its own kubelet build there (ghcr.io/siderolabs/kubelet), separate from registry.k8s.io"
  type        = string
  default     = "5002"
}
