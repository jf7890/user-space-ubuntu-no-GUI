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
          eth0:
            dhcp4: true
            dhcp6: false
            optional: true
            dhcp-identifier: mac
          ens18:
            dhcp4: true
            dhcp6: false
            optional: true
            dhcp-identifier: mac

      packages:
        - qemu-guest-agent
        - sudo

      late-commands:
        - curtin in-target -- systemctl enable ssh
        - curtin in-target -- /bin/sh -c "echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu"
        - curtin in-target -- chmod 440 /etc/sudoers.d/ubuntu
        - curtin in-target -- /bin/sh -c "mkdir -p /etc/cloud/cloud.cfg.d"
        - curtin in-target -- /bin/sh -c "printf '%s\n' 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"
        - curtin in-target -- /bin/sh -c "rm -f /etc/netplan/50-cloud-init.yaml"
        - curtin in-target -- /bin/sh -c "printf '%s\n' 'network:' '  version: 2' '  renderer: networkd' '  ethernets:' '    eth0:' '      dhcp4: true' '      dhcp6: false' '      optional: true' '    ens18:' '      dhcp4: true' '      dhcp6: false' '      optional: true' > /etc/netplan/01-netcfg.yaml"
        - curtin in-target -- /bin/sh -c "netplan generate >/dev/null 2>&1 || true"
        - curtin in-target -- systemctl disable --now systemd-networkd-wait-online.service > /dev/null 2>&1 || true
        - curtin in-target -- systemctl disable --now NetworkManager-wait-online.service > /dev/null 2>&1 || true
