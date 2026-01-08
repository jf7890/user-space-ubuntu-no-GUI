packer {
  required_plugins {
    proxmox = {
      source  = "github.com/hashicorp/proxmox"
      version = ">= 1.2.0"
    }
  }
}

// --- VM template build ---
source "proxmox-iso" "kali-xfce" {
  # Proxmox
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  insecure_skip_tls_verify = var.proxmox_skip_tls_verify
  node                     = var.proxmox_node

  # VM general
  vm_id                = var.template_vm_id
  vm_name              = var.template_name
  template_description = var.template_description
  os                   = "l26"

  # ISO
  iso_url          = var.kali_iso_url
  iso_checksum     = var.kali_iso_checksum
  iso_storage_pool = var.iso_storage
  unmount_iso      = true

  # Guest
  qemu_agent      = true
  scsi_controller = "virtio-scsi-pci"

  disks {
    disk_size    = var.disk_size
    format       = "raw" # local-lvm typically requires raw
    storage_pool = var.vm_storage
    type         = "virtio"
  }

  cores              = var.cores
  memory             = var.memory
  ballooning_minimum = var.ballooning_minimum

  # Network: 2 NICs (WAN for build/install; LAN for lab)
  network_adapters {
    model    = "virtio"
    bridge   = var.bridge_wan
    firewall = false
  }
  network_adapters {
    model    = "virtio"
    bridge   = var.bridge_lan
    firewall = false
    vlan_tag = var.lan_vlan_tag
  }

  vga {
    type   = "std"
    memory = 64
  }

  # Cloud-init drive (so clones can use cloud-init if you want)
  cloud_init              = true
  cloud_init_storage_pool = var.proxmox_storage

  # Unattended install via preseed
  boot_command = [
    "<esc><wait>",
    "<esc><wait>",
    "<esc><wait>",
    "install preseed/url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/cloud.cfg debian-installer=en_US auto locale=en_US kbd-chooser/method=us <wait>",
    "netcfg/get_hostname=kali netcfg/get_domain=local fb=false debconf/frontend=noninteractive console-setup/ask_detect=false <wait>",
    "console-keymaps-at/keymap=us keyboard-configuration/xkb-keymap=us <wait>",
    "<enter><wait>"
  ]
  boot      = "c"
  boot_wait = "5s"

  http_directory    = "http"
  http_bind_address = "0.0.0.0"
  http_port_min     = 8902
  http_port_max     = 8902

  ssh_username = "kali"
  ssh_password = "kali"
  ssh_timeout  = "2h"

  # If you provide PACKER_SSH_PRIVATE_KEY_FILE, packer will prefer it.
  ssh_private_key_file = var.ssh_private_key_file != "" ? var.ssh_private_key_file : null
}

build {
  name    = "kali"
  sources = ["source.proxmox-iso.kali-xfce"]

  # Proxmox cloud-init tweaks
  provisioner "file" {
    source      = "files/99-pve.cfg"
    destination = "/tmp/99-pve.cfg"
  }

  # User stack + provision script
  provisioner "file" {
    source      = "files/userstack/"
    destination = "/tmp/capstone-userstack"
  }

  provisioner "file" {
    source      = "scripts/"
    destination = "/tmp/scripts"
  }

  provisioner "shell" {
    environment_vars = [
      "PACKER_SSH_PUBLIC_KEY=${var.ssh_public_key}",
    ]
    inline = [
      "echo 'kali' | sudo -S cp /tmp/99-pve.cfg /etc/cloud/cloud.cfg.d/99-pve.cfg",
      "echo 'kali' | sudo -S bash /tmp/scripts/provision-kali-userstack.sh",
    ]
  }
}
