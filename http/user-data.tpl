#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  timezone: Asia/Ho_Chi_Minh

  identity:
    hostname: ${hostname}
    username: ubuntu
    password: "${ubuntu_password_hash}"

  ssh:
    install-server: true
    allow-pw: true
%{ if ssh_public_key != "" }
    authorized-keys:
      - "${ssh_public_key}"
%{ endif }

  network:
    version: 2
    ethernets:
      ens18:
        dhcp4: true
        dhcp6: false
        optional: true

  packages:
    - qemu-guest-agent
    - sudo

  late-commands:
    - curtin in-target -- systemctl enable ssh
    - curtin in-target -- /bin/sh -c "echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu"
    - curtin in-target -- chmod 440 /etc/sudoers.d/ubuntu
