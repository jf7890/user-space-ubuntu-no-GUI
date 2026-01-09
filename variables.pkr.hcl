// variables.pkr.hcl
// Use PKR_VAR_* environment variables (Packer built-in). No custom parsing functions needed.

variable "proxmox_url" {
  type = string
}

variable "proxmox_username" {
  type = string
}

variable "proxmox_token" {
  type      = string
  sensitive = true
}

variable "proxmox_node" {
  type = string
}

variable "proxmox_skip_tls_verify" {
  type    = bool
  default = true
}

variable "iso_storage" {
  type = string
}

variable "vm_storage" {
  type = string
}

variable "proxmox_storage" {
  type = string
}

variable "bridge_wan" {
  type = string
  default = env("PACKER_BRIDGE_WAN")
}

variable "bridge_lan" {
  type = string
  default = env("PACKER_BRIDGE_LAN")
}

variable "lan_vlan_tag" {
  type    = number
  default = 0
}

variable "ssh_public_key" {
  type    = string
  default = env("PACKER_SSH_PUBLIC_KEY")
}

variable "ssh_private_key_file" {
  type    = string
  default = env("PACKER_SSH_PRIVATE_KEY")
}

variable "template_vm_id" {
  type = number
}

variable "template_name" {
  type = string
}

variable "template_description" {
  type    = string
  default = "Kali XFCE (Capstone)"
}

variable "cores" {
  type    = number
  default = 2
}

variable "memory" {
  type    = number
  default = 4096
}

variable "ballooning_minimum" {
  type    = number
  default = 0
}

variable "disk_size" {
  type    = string
  default = "30G"
}

variable "kali_iso_url" {
  type = string
}

variable "kali_iso_checksum" {
  type    = string
  default = "none"
}
