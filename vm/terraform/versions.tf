terraform {
  required_version = ">= 1.7.0"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9.5"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}
