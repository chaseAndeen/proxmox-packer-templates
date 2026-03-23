packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.2"
      source  = "github.com/hashicorp/proxmox"
    }
    ansible = {
      version = ">= 1.1.1"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

# ---------------------------------------------------------------------------
# Shared variables — used by all builds
# Values supplied via variables.pkrvars.hcl at build time
# ---------------------------------------------------------------------------

variable "proxmox_host" {
  type        = string
  description = "Proxmox node FQDN or IP (e.g. alpha-site.infra.kernelstack.dev)"
}

variable "proxmox_port" {
  type    = number
  default = 8006
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node name (e.g. alpha-site)"
}

variable "proxmox_token_id" {
  type    = string
  default = "packer-builder@pve!packer-token"
}

variable "proxmox_token_secret" {
  type      = string
  sensitive = true
}

variable "storage_pool" {
  type        = string
  description = "Proxmox storage pool for VM disks — must be ZFS or LVM (e.g. datashard)"
}

variable "iso_storage_pool" {
  type        = string
  default     = "local"
  description = "Proxmox storage pool for ISOs — must be dir type (e.g. local)"
}

variable "template_id" {
  type        = number
  description = "Proxmox VM ID for the template — set by build.sh per target (ubuntu: 9000, debian: 9001)"
}
