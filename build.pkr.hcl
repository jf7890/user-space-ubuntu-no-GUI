
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
    inline = [ "sudo cp /tmp/99-pve.cfg /etc/cloud/cloud.cfg.d/99-pve.cfg" ]
  }
}