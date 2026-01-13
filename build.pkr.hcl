
build {
  name    = "kali"
  sources = ["source.proxmox-iso.kali-xfce"]

  # Proxmox cloud-init tweaks
  provisioner "file" {
    source      = "files/99-pve.cfg"
    destination = "/tmp/99-pve.cfg"
  }

  # User stack + provision script
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /tmp/capstone-userstack-src",
      "sudo mkdir -p /tmp/capstone-scripts"
    ]
  }

  provisioner "file" {
    source      = "files/userstack/"
    destination = "/tmp/capstone-userstack-src"
  }

  provisioner "file" {
    source      = "scripts/"
    destination = "/tmp/capstone-scripts/"
  }

  provisioner "shell" {
    inline = [
      "sudo rm -rf /opt/capstone-userstack-src /opt/capstone-scripts",
      "sudo mkdir -p /opt/capstone-userstack-src /opt/capstone-scripts",
      "sudo cp -a /tmp/capstone-userstack-src/. /opt/capstone-userstack-src/",
      "sudo cp -a /tmp/capstone-scripts/. /opt/capstone-scripts/",
      "sudo chmod +x /opt/capstone-scripts/*.sh",
      "sudo bash -c 'cat > /etc/systemd/system/capstone-firstboot.service <<\"EOF\"\n[Unit]\nDescription=Capstone first boot provisioning\nWants=network-online.target\nAfter=network-online.target\nConditionPathExists=/opt/capstone-scripts/provision-kali-userstack.sh\nConditionPathExists=!/var/lib/capstone-userstack/provisioned\n\n[Service]\nType=oneshot\nExecStart=/opt/capstone-scripts/provision-kali-userstack.sh\nRemainAfterExit=yes\nTimeoutStartSec=0\n\n[Install]\nWantedBy=multi-user.target\nEOF'",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable capstone-firstboot.service"
    ]
  }

  provisioner "shell" {
    inline = ["sudo cp /tmp/99-pve.cfg /etc/cloud/cloud.cfg.d/99-pve.cfg"]
  }

  provisioner "shell" {
    inline = [
      "sudo rm -rf /tmp/capstone-userstack-src /tmp/capstone-scripts 2>/dev/null || true",
      "sudo rm -f /root/.ssh/authorized_keys /home/kali/.ssh/authorized_keys 2>/dev/null || true",
      "sudo rm -f /etc/ssh/ssh_host_* 2>/dev/null || true",
      "sudo truncate -s 0 /etc/machine-id 2>/dev/null || true",
      "sudo rm -f /var/lib/dbus/machine-id 2>/dev/null || true",
      "sudo find /var/log -type f -exec truncate -s 0 {} \\; 2>/dev/null || true",
      "sudo rm -f /root/.bash_history /home/kali/.bash_history 2>/dev/null || true",
      "sudo rm -rf /var/lib/apt/lists/* 2>/dev/null || true",
      "sudo sync || true"
    ]
  }
}
