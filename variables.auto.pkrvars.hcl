# variables.auto.pkrvars.hcl

proxmox_url      = "https://10.10.100.1:8006/api2/json"
proxmox_username = "root@pam!packer"
proxmox_token    = "28786dd2-1eed-44e6-b8a4-dc2221ce384d"
proxmox_node     = "homelab"
proxmox_skip_tls_verify  = true

iso_storage              = "hdd-data"
vm_storage               = "local-lvm"
proxmox_storage          = "local-lvm"

template_vm_id           = 9001
template_name            = "tpl-kali-xfce"
template_description     = "Kali XFCE (Capstone)"

cores                    = 2
memory                   = 4096
ballooning_minimum       = 0
disk_size                = "30G"

# Kali ISO (Installer amd64) + checksum
kali_iso_url             = "https://cdimage.kali.org/kali-2025.3/kali-linux-2025.3-installer-netinst-amd64.iso"
kali_iso_checksum        = "file:https://cdimage.kali.org/kali-2025.3/SHA256SUMS"