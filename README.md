# Capstone Kali XFCE template (Proxmox + Packer)

This repo builds a **Kali XFCE** Proxmox template using Packer, and bakes in a "user stack":
- DVWA
- Juice Shop (+ Postgres)
- nginx-love (backend + frontend + bootstrap)
- Wazuh **agent on the Kali host** (disabled by default until you set the manager IP)

## 1) Requirements
- Packer installed on your workstation/runner
- Proxmox reachable from the runner
- Internet access for the Kali installer + apt (during build)

## 2) Environment variables (no *.pkrvars)
Set these **in your shell environment** before running packer:

### Proxmox
- `PROXMOX_URL` (example: `https://10.10.100.1:8006/api2/json`)
- `PROXMOX_USERNAME` (token user, example: `user@pam!packer`)
- `PROXMOX_TOKEN` (token **secret**)
- `PROXMOX_NODE` (example: `homelab`)
- `PROXMOX_SKIP_TLS_VERIFY` (`true` / `false`, default: `true`)

### Storage
- `PACKER_ISO_STORAGE` (where ISO is stored; often `local`)
- `PACKER_VM_STORAGE` (VM disks; often `local-lvm`)
- `PACKER_PROXMOX_STORAGE` (optional; default = `PACKER_VM_STORAGE`)

### Network bridges
- `PACKER_BRIDGE_WAN` (internet bridge for installer, example: `vmbr0`)
- `PACKER_BRIDGE_LAN` (internal lab bridge, example: `nonet`)
- `PACKER_LAN_VLAN_TAG` (optional; numeric; default: `0`)

### SSH keys (optional but recommended)
- `PACKER_SSH_PUBLIC_KEY`
- `PACKER_SSH_PRIVATE_KEY_FILE`

## 3) Build
```bash
cd capstone-packer-kali-template-main
packer init .
packer validate .
packer build .
```

## 4) After you create a VM from the template
### Start the lab stack
```bash
sudo systemctl start capstone-userstack
sudo docker ps
```

### Open the apps (from the Kali host)
- DVWA: `http://127.0.0.1:8080`
- Juice Shop: `http://127.0.0.1:3000`
- nginx-love frontend: `http://127.0.0.1:8081`
- nginx-love backend API: `http://127.0.0.1:5044`

### Point the Wazuh agent to your manager (ONE-TIME)
```bash
sudo wazuh-set-manager <WAZUH_MANAGER_IP>
```

## 5) Troubleshooting quick checks
- Docker running: `systemctl status docker --no-pager`
- Stack status: `docker compose -f /opt/capstone-userstack/docker-compose.yml ps`
- Logs exist:
  - `/opt/capstone-userstack/logs/nginx/*.log`
  - `/opt/capstone-userstack/logs/modsecurity/modsec_audit.log`
- Wazuh agent:
  - `systemctl status wazuh-agent --no-pager`
  - `sudo grep -n "CAPSTONE_USERSTACK_LOGS" /var/ossec/etc/ossec.conf`
