proxmox_skip_tls_verify = true

vm_storage      = "local-lvm"
proxmox_storage = "local-lvm"

template_vm_id       = 0
template_name        = "tpl-kali-xfce"
template_description = "Kali XFCE (Capstone)"

cores              = 4
memory             = 6144
ballooning_minimum = 0
disk_size          = "30G"

# Kali ISO (Installer amd64) + checksum
kali_iso_url             = "https://cdimage.kali.org/kali-2025.4/kali-linux-2025.4-installer-amd64.iso"
kali_iso_checksum        = "sha256:3b4a3a9f5fb6532635800d3eda94414fb69a44165af6db6fa39c0bdae750c266"

lan_vlan_tag = 10
task_timeout = "2h"