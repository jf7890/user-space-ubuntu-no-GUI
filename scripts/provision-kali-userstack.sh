#!/usr/bin/env bash
set -euo pipefail

# This script is intended to run as root (packer runs it via sudo).

USERSTACK_SRC="/tmp/capstone-userstack"
USERSTACK_DST="/opt/capstone-userstack"

export DEBIAN_FRONTEND=noninteractive

echo "[1/8] Apt update + base packages"
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release jq \
  qemu-guest-agent \
  docker.io docker-compose-plugin \
  unzip

systemctl enable --now qemu-guest-agent || true
systemctl enable --now docker

# Allow 'kali' user to run docker without sudo (if the user exists)
if id kali >/dev/null 2>&1; then
  usermod -aG docker kali || true
fi

echo "[2/8] Install Wazuh agent (optional; does not start until manager is set)"
# Wazuh provides Debian/Ubuntu repo that works for Kali (Debian-based).
# If your environment blocks external downloads, you can comment this section.
if ! dpkg -s wazuh-agent >/dev/null 2>&1; then
  curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
  echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
  apt-get update -y
  apt-get install -y wazuh-agent
fi

# Placeholders: we keep the agent disabled by default (manager IP to be set later)
WAZUH_CONF="/var/ossec/etc/ossec.conf"
if [[ -f "$WAZUH_CONF" ]]; then
  # Make sure we have a deterministic placeholder address
  sed -i 's|<address>[^<]*</address>|<address>__WAZUH_MANAGER__</address>|' "$WAZUH_CONF" || true

  # Add logcollector entries once
  if ! grep -q "CAPSTONE_USERSTACK_LOGS" "$WAZUH_CONF"; then
    # Insert before closing tag
    perl -0777 -i -pe 's#</ossec_config>#  <!-- CAPSTONE_USERSTACK_LOGS -->\n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/opt/capstone-userstack/logs/nginx/access.log</location>\n  </localfile>\n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/opt/capstone-userstack/logs/nginx/error.log</location>\n  </localfile>\n  <localfile>\n    <log_format>json</log_format>\n    <location>/opt/capstone-userstack/logs/modsecurity/modsec_audit.log</location>\n  </localfile>\n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/opt/capstone-userstack/logs/apache/access.log</location>\n  </localfile>\n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/opt/capstone-userstack/logs/apache/error.log</location>\n  </localfile>\n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/opt/capstone-userstack/logs/mysql/error.log</location>\n  </localfile>\n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/opt/capstone-userstack/logs/postgres/postgresql.log</location>\n  </localfile>\n</ossec_config>#s' "$WAZUH_CONF"
  fi
fi

systemctl stop wazuh-agent || true
systemctl disable wazuh-agent || true

echo "[3/8] Helper: set Wazuh manager IP later"
cat > /usr/local/bin/wazuh-set-manager <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "Usage: wazuh-set-manager <MANAGER_IP_OR_HOSTNAME>" >&2
  exit 1
fi
mgr="$1"
conf="/var/ossec/etc/ossec.conf"
if [[ ! -f "$conf" ]]; then
  echo "Cannot find $conf" >&2
  exit 1
fi
sed -i "s|<address>__WAZUH_MANAGER__</address>|<address>${mgr}</address>|" "$conf"
systemctl enable --now wazuh-agent
systemctl restart wazuh-agent
systemctl status wazuh-agent --no-pager
EOF
chmod +x /usr/local/bin/wazuh-set-manager

echo "[4/8] Install capstone userstack files"
rm -rf "$USERSTACK_DST"
mkdir -p "$USERSTACK_DST"
cp -a "$USERSTACK_SRC"/* "$USERSTACK_DST"/

# Ensure logs dirs exist
mkdir -p \
  "$USERSTACK_DST/logs/nginx" \
  "$USERSTACK_DST/logs/modsecurity" \
  "$USERSTACK_DST/logs/apache" \
  "$USERSTACK_DST/logs/mysql" \
  "$USERSTACK_DST/logs/postgres" \
  "$USERSTACK_DST/logs/juiceshop"

# Create .env from template if missing
if [[ -f "$USERSTACK_DST/.env.example" && ! -f "$USERSTACK_DST/.env" ]]; then
  cp "$USERSTACK_DST/.env.example" "$USERSTACK_DST/.env"
fi

chmod +x "$USERSTACK_DST/scripts"/*.sh || true

echo "[5/8] Create systemd service: capstone-userstack"
cat > /etc/systemd/system/capstone-userstack.service <<'EOF'
[Unit]
Description=Capstone user lab stack (DVWA + JuiceShop + nginx-love)
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/capstone-userstack
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable capstone-userstack.service

echo "[6/8] Pre-pull/build docker images (best-effort)"
# Avoid failing the whole template build if a registry is down.
(
  cd "$USERSTACK_DST"
  docker compose pull || true
  # frontend/bootstrap are built locally
  docker compose build --pull || true
) || true

# Do not start the lab automatically during the template build
systemctl stop capstone-userstack.service || true

echo "[7/8] Optional: inject SSH public key for the 'kali' user"
if [[ -n "${PACKER_SSH_PUBLIC_KEY:-}" && -d /home/kali ]]; then
  install -d -m 0700 -o kali -g kali /home/kali/.ssh
  echo "$PACKER_SSH_PUBLIC_KEY" > /home/kali/.ssh/authorized_keys
  chown kali:kali /home/kali/.ssh/authorized_keys
  chmod 0600 /home/kali/.ssh/authorized_keys
fi

echo "[8/8] Cleanup"
rm -rf /tmp/capstone-userstack /tmp/scripts || true
apt-get autoremove -y || true
apt-get clean

echo "DONE: Template has docker + userstack + wazuh-agent (disabled until manager set)."
