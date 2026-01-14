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

  task_timeout = var.task_timeout

  # VM general
  vm_id                = var.template_vm_id
  vm_name              = var.template_name
  template_description = var.template_description
  os                   = "l26"

  boot_iso {
    type = "scsi"

    iso_url          = var.kali_iso_url
    iso_checksum     = var.kali_iso_checksum
    iso_storage_pool = var.iso_storage
    iso_download_pve = true
    unmount          = true
  }

  # Guest
  qemu_agent      = true
  scsi_controller = "virtio-scsi-pci"

  disks {
    disk_size    = var.disk_size
    format       = "raw"
    storage_pool = var.vm_storage
    type         = "virtio"
  }

  cores              = var.cores
  memory             = var.memory
  ballooning_minimum = var.ballooning_minimum

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

  boot_command = [
    "<esc><wait>",
    "<esc><wait>",
    "<esc><wait>",

    "install auto=true priority=critical desktop=xfce debconf/frontend=noninteractive ",
    "preseed/url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/cloud.cfg ",
    "debian-installer/locale=en_US.UTF-8 locale=en_US.UTF-8 ",
    "keyboard-configuration/xkb-keymap=us console-keymaps-at/keymap=us ",
    "netcfg/choose_interface=auto netcfg/get_hostname=kali netcfg/get_domain=local ",
    "fb=false console-setup/ask_detect=false <wait>",

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