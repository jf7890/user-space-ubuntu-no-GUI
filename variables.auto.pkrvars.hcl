# variables.auto.pkrvars.hcl
# (Giá trị demo - bạn chỉnh lại sau)

proxmox_url              = "https://pve.example.local:8006/api2/json"
proxmox_username         = "root@pam"
proxmox_token            = "root@pam!packer=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
proxmox_node             = "pve-node1"
proxmox_skip_tls_verify  = true

iso_storage              = "local"
vm_storage               = "local-lvm"
proxmox_storage          = "local-lvm"

lan_vlan_tag             = 10

template_vm_id           = 9001
template_name            = "tpl-kali-xfce"
template_description     = "Kali XFCE (Capstone)"

cores                    = 2
memory                   = 4096
ballooning_minimum       = 0
disk_size                = "30G"

# Kali ISO (Installer amd64) + checksum
kali_iso_url             = "https://kali.download/base-images/current/kali-linux-2025.4-installer-amd64.iso"
kali_iso_checksum        = "sha256:3b4a3a9f5fb6532635800d3eda94414fb69a44165af6db6fa39c0bdae750c266"