# packer-templates

Packer builds for golden VM templates on Proxmox VE.

Currently produces:
- `tpl-ubuntu-noble` (VM ID 9000) — Ubuntu 24.04 LTS
- `tpl-debian-bookworm` (VM ID 9001) — Debian 12

---

## Design principles

The golden image is intentionally generic. It contains OS-level hardening and
infrastructure tooling that every VM needs regardless of its role.

**User accounts and SSH keys are NOT baked in.** These are applied at deploy
time by Terraform via cloud-init. This means you can rotate keys, change
usernames, or reprovision VMs without rebuilding the template.

---

## What gets baked in

| Category | Details |
|---|---|
| OS | Full dist-upgrade at build time |
| Timezone | UTC |
| NTP | chrony, pool.ntp.org |
| Security patching | unattended-upgrades (security only, auto-reboot 02:00) |
| SSH | Port 2222, no root, no passwords, strong ciphers only |
| QEMU | qemu-guest-agent enabled |
| Storage | fstrim.timer enabled |
| Logging | journald capped at 500MB |
| Cloud-init | Installed, datasource limited to NoCloud/ConfigDrive (faster boot) |
| Packages | sudo, curl, wget, ca-certificates, gnupg, python3, cloud-init, vim, tmux, htop |
| Cleanup | machine-id truncated, SSH host keys removed, cloud-init reset |

## What is NOT baked in (handled by Terraform + cloud-init)

- User accounts and SSH authorized keys
- Hostname
- IP / network config
- Application packages and config

---

## Host machine requirements

### WSL2 mirrored networking (required for Debian builds)
Packer's built-in HTTP server is hardcoded to `10.255.255.254` in the proxmox
plugin and is unreachable by Proxmox VMs. For Debian, `build.sh` runs its own
HTTP server to serve the preseed. This requires WSL to have a real LAN IP.

Add to `C:\Users\<you>\.wslconfig`:
```ini
[wsl2]
networkingMode=mirrored
```

Then restart WSL:
```powershell
wsl --shutdown
```

Verify WSL has a LAN IP (should be `192.168.x.x`, not `172.x.x.x`):
```bash
ip addr show eth0 | grep "inet "
```

### Windows Firewall rule (required for Debian builds)
Even with mirrored networking, Windows Firewall blocks inbound connections to
WSL processes. Add a rule to allow the preseed HTTP server:

```powershell
New-NetFirewallRule -DisplayName "Packer Preseed HTTP" -Direction Inbound -Protocol TCP -LocalPort 8118 -Action Allow
```

This is a one-time setup and persists across reboots.

---

## Dependencies

### Quick install (all at once)
```bash
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y packer ansible xorriso
ansible-galaxy collection install ansible.posix community.general
```

### Individual dependencies

| Dependency | Purpose | Install |
|---|---|---|
| Packer | Build orchestrator | HashiCorp apt repo (see above) |
| Packer plugins | proxmox + ansible | Auto-installed via `packer init` |
| Ansible | VM provisioning | `sudo apt-get install -y ansible` |
| Ansible collections | posix + general | `ansible-galaxy collection install ansible.posix community.general` |
| xorriso | Build Ubuntu cidata seed ISO | `sudo apt-get install -y xorriso` |
| AWS CLI | Fetch secrets from SSM | See below |

### AWS CLI
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install && rm -rf awscliv2.zip aws/
aws configure sso --profile InfraProvisioner
```

---

## AWS SSM parameters required

| Parameter | Type | Description |
|---|---|---|
| `/infra/proxmox/packer_token` | SecureString | Packer API token secret |

---

## Proxmox requirements

### Storage

| Storage | Type | Used for |
|---|---|---|
| `datashard` | zfspool | VM disks, cloud-init drives |
| `local` | dir | ISO downloads, seed ISOs |

> ZFS pool storage does not support ISO content type. ISOs must go to `local` (dir type).

### PackerRole privileges
```
Datastore.Allocate, Datastore.AllocateSpace, Datastore.AllocateTemplate, Datastore.Audit,
SDN.Use, Sys.AccessNetwork, Sys.Audit, Sys.Console, Sys.Modify,
VM.Allocate, VM.Audit, VM.Clone, VM.Config.CDROM, VM.Config.CPU, VM.Config.Cloudinit,
VM.Config.Disk, VM.Config.HWType, VM.Config.Memory, VM.Config.Network, VM.Config.Options,
VM.Console, VM.PowerMgmt, VM.GuestAgent.Audit, VM.GuestAgent.Unrestricted
```

Managed by `proxmox-playbook` — run `ansible-playbook site.yml --tags packer` to apply.

---

## Setup

```bash
git clone <repo-url>
cd packer-templates
cp variables.pkrvars.hcl.example variables.pkrvars.hcl
# Edit variables.pkrvars.hcl with your values
chmod +x build.sh
```

---

## Running a build

```bash
./build.sh ubuntu-noble
./build.sh debian-bookworm
```

**First run:** Proxmox downloads the ISO directly (~3GB Ubuntu, ~670MB Debian).
Subsequent builds reuse the cached ISO.

**Build time:** ~15-20 min Ubuntu, ~20-25 min Debian.

---

## Build flow

### Ubuntu
```
build.sh
  ├── SSM: fetch packer_token
  └── packer build
        ├── Proxmox: download ISO (if not cached)
        ├── Proxmox: create build VM + attach ISO + cidata seed ISO
        ├── VM boots → Ubuntu autoinstall runs (~10 min)
        ├── Packer: SSH in as root
        ├── Ansible: provision.yml
        └── Proxmox: convert to template (ID 9000)
```

### Debian
```
build.sh
  ├── Start python3 HTTP server on WSL LAN IP:8118 (serves preseed.cfg)
  ├── SSM: fetch packer_token
  └── packer build
        ├── Proxmox: download ISO (if not cached)
        ├── Proxmox: create build VM
        ├── VM boots → fetches preseed from http://192.168.x.x:8118/preseed.cfg
        ├── Debian installer runs automated install (~15 min)
        ├── Packer: SSH in as root
        ├── Ansible: provision.yml
        └── Proxmox: convert to template (ID 9001)
  └── Stop python3 HTTP server
```

---

## Troubleshooting

**`could not find a supported CD ISO creation command`**
Install xorriso: `sudo apt-get install -y xorriso`

**`401 Authentication failed` on ISO download**
PackerRole is missing `Sys.Modify` or `Datastore.AllocateTemplate`. Re-run `proxmox-playbook` with `--tags packer`.

**`403 Permission check failed (VM.GuestAgent)`**
PackerRole is missing `VM.GuestAgent.Audit` and `VM.GuestAgent.Unrestricted`.

**Debian installer sits on blue screen for 15+ minutes**
The preseed HTTP server is blocked by Windows Firewall. Add the firewall rule:
`New-NetFirewallRule -DisplayName "Packer Preseed HTTP" -Direction Inbound -Protocol TCP -LocalPort 8118 -Action Allow`

**Debian preseed URL shows `10.255.255.254`**
WSL mirrored networking is not enabled or `http_interface` is being ignored by
the proxmox plugin. `build.sh` works around this by running its own HTTP server
— ensure the firewall rule above is in place.

**ISO download times out**
`task_timeout = "30m"` is set. Increase if on a slow connection.

**`iso_storage_pool` 401 error**
`iso_storage_pool` must be a `dir` type storage (e.g. `local`), not a ZFS pool.

**SSH timeout waiting for VM**
`ssh_timeout = "30m"` covers the OS install. Check the VM console in Proxmox UI.
