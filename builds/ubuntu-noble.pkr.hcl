# packer {} block and shared variables are in variables.pkr.hcl
# template_id passed by build.sh via -var (ubuntu: 9000, debian: 9001)

# ---------------------------------------------------------------------------
# Source
# ---------------------------------------------------------------------------

source "proxmox-iso" "ubuntu-noble" {
  # Connection
  proxmox_url              = "https://${var.proxmox_host}:${var.proxmox_port}/api2/json"
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = true
  node                     = var.proxmox_node

  # Template identity
  vm_id   = var.template_id
  vm_name = "tpl-ubuntu-noble"
  tags    = "template;ubuntu;noble"

  # ISO — Proxmox downloads directly. Skips download if already cached.
  boot_iso {
    type             = "ide"
    iso_url          = "https://releases.ubuntu.com/24.04/ubuntu-24.04.3-live-server-amd64.iso"
    iso_checksum     = "sha256:c3514bf0056180d09376462a7a1b4f213c1d6e8ea67fae5c25099c6fd3d8274b"
    iso_storage_pool = var.iso_storage_pool
    iso_download_pve = true
    unmount          = true
  }

  task_timeout = "30m"

  # Hardware
  cores           = 2
  memory          = 2048
  cpu_type        = "host"
  os              = "l26"
  scsi_controller = "virtio-scsi-single"
  qemu_agent      = true

  # Boot disk
  disks {
    type         = "scsi"
    disk_size    = "20G"
    storage_pool = var.storage_pool
    format       = "raw"
    io_thread    = true
  }

  # Network
  network_adapters {
    model  = "virtio"
    bridge = "vmbr0"
  }

  # Cloud-init drive — Terraform uses this to set hostname/IP/user at clone time
  cloud_init              = true
  cloud_init_storage_pool = var.storage_pool

  # Autoinstall seed ISO — index 1, boot_iso occupies ide index 0
  additional_iso_files {
    type             = "ide"
    index            = 1
    iso_storage_pool = var.iso_storage_pool
    cd_files = [
      "../http/ubuntu/user-data",
      "../http/ubuntu/meta-data"
    ]
    cd_label = "cidata"
  }

  boot_wait = "3s"
  boot_command = [
    "<wait5>",
    "<wait5>",
    "<wait5>",
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ds=nocloud;s=/cidata/ net.ifnames=0 biosdevname=0",
    "<enter><wait>",
    "initrd /casper/initrd",
    "<enter><wait>",
    "boot",
    "<enter>"
  ]

  # Packer SSHs in as the temporary 'packer' user created by autoinstall
  # This user is removed by provision.yml after provisioning
  ssh_username           = "packer"
  ssh_password           = "PackerBuild"
  ssh_timeout            = "30m"
  ssh_port               = 22
  ssh_handshake_attempts = 50

  template_description = "Ubuntu 24.04 Noble golden image — built with Packer on ${timestamp()}"
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

build {
  name    = "ubuntu-noble"
  sources = ["source.proxmox-iso.ubuntu-noble"]

  provisioner "ansible" {
    playbook_file = "../ansible/provision.yml"
    use_sftp      = true
  }
}
