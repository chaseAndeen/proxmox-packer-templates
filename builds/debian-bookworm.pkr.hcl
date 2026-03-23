# packer {} block and shared variables are in variables.pkr.hcl
# template_id passed by build.sh via -var (ubuntu: 9000, debian: 9001)

variable "preseed_url" {
  type        = string
  description = "Full URL to preseed.cfg — set automatically by build.sh"
  default     = ""
}

# ---------------------------------------------------------------------------
# Source
# ---------------------------------------------------------------------------

source "proxmox-iso" "debian-bookworm" {
  # Connection
  proxmox_url              = "https://${var.proxmox_host}:${var.proxmox_port}/api2/json"
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = true
  node                     = var.proxmox_node

  # Template identity
  vm_id   = var.template_id
  vm_name = "tpl-debian-bookworm"
  tags    = "template;debian;bookworm"

  # ISO — Proxmox downloads directly. Skips download if already cached.
  boot_iso {
    type             = "ide"
    iso_url          = "https://cdimage.debian.org/images/archive/12.12.0/amd64/iso-cd/debian-12.12.0-amd64-netinst.iso"
    iso_checksum     = "sha256:dfc30e04fd095ac2c07e998f145e94bb8f7d3a8eca3a631d2eb012398deae531"
    iso_storage_pool = var.iso_storage_pool
    iso_download_pve = true
    unmount          = true
  }

  task_timeout = "30m"

  # Hardware
  cores           = 2
  memory          = 2048
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

  # Preseed served by build.sh via python3 http.server on the WSL LAN IP
  # Packer's {{.HTTPIP}} is hardcoded to 10.255.255.254 in the proxmox plugin
  # and unreachable by VMs — build.sh manages the HTTP server and passes the URL
  boot_wait = "10s"
  boot_command = [
    "<esc><wait3>",
    "auto preseed/url=${var.preseed_url} ",
    "debian-installer=en_US.UTF-8 ",
    "auto=true ",
    "locale=en_US.UTF-8 ",
    "kbd-chooser/method=us ",
    "keyboard-configuration/xkb-keymap=us ",
    "netcfg/get_hostname=packer-build ",
    "netcfg/get_domain=local ",
    "fb=false ",
    "debconf/frontend=noninteractive ",
    "console-setup/ask_detect=false ",
    "console-keymaps-at/keymap=us ",
    "<enter>"
  ]

  # Packer SSHs in as the temporary 'packer' user created by preseed
  # This user is removed by provision.yml after provisioning
  ssh_username           = "packer"
  ssh_password           = "PackerBuild"
  ssh_timeout            = "30m"
  ssh_port               = 22
  ssh_handshake_attempts = 50

  template_description = "Debian 12 Bookworm golden image — built with Packer on ${timestamp()}"
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

build {
  name    = "debian-bookworm"
  sources = ["source.proxmox-iso.debian-bookworm"]

  provisioner "ansible" {
    playbook_file = "../ansible/provision.yml"
    use_sftp      = true
  }
}
