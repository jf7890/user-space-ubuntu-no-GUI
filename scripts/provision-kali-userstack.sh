#!/usr/bin/env bash
set -euo pipefail

# Script chạy bởi quyền root (qua Packer)

USERSTACK_SRC="/tmp/capstone-userstack"
USERSTACK_DST="/opt/capstone-userstack"
export DEBIAN_FRONTEND=noninteractive

echo "[1/11] Fix Sources List & Update"
cat > /etc/apt/sources.list <<EOF
deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
# deb-src http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
EOF

apt-get update -y

echo "[2/11] Install Cloud-init, VNC & tools"
# Cài thêm các gói thiếu vì không cài trong Preseed
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg jq unzip npm \
  cloud-init tigervnc-standalone-server tigervnc-common tigervnc-tools dbus-x11 \
  git \
  nmap \
  sqlmap \
  nikto

# Docker CE (official)
DOCKER_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
if [[ "$DOCKER_CODENAME" == "kali-rolling" ]]; then
  DOCKER_CODENAME="bookworm"
fi

apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc || true
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${DOCKER_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y --no-install-recommends \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Enable cloud-init units that exist
for svc in cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service; do
  if systemctl list-unit-files "$svc" --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "$svc"; then
    systemctl enable "$svc"
  else
    echo "Skipping enable $svc (unit not found)"
  fi
done

if command -v docker >/dev/null 2>&1; then
  systemctl enable --now docker
  # Allow 'kali' user to run docker
  if id kali >/dev/null 2>&1; then
    usermod -aG docker kali || true
  fi
else
  echo "Skipping docker enable (docker not installed)"
fi

echo "[3/11] Configure VNC (XFCE)"
if ! id kali >/dev/null 2>&1; then
  echo "Skipping VNC setup (user kali not found)"
elif ! command -v vncpasswd >/dev/null 2>&1 || ! command -v vncserver >/dev/null 2>&1; then
  echo "Skipping VNC setup (tigervnc not installed)"
else
  VNC_PASSWORD="${VNC_PASSWORD:-kali1234}"
  install -d -m 0700 -o kali -g kali /home/kali/.vnc

  cat > /home/kali/.vnc/xstartup <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export SHELL=/bin/bash
startxfce4 &
EOF
  chown kali:kali /home/kali/.vnc/xstartup
  chmod 755 /home/kali/.vnc/xstartup

  su - kali -c "printf '%s\n' \"${VNC_PASSWORD}\" | vncpasswd -f > ~/.vnc/passwd"
  chmod 600 /home/kali/.vnc/passwd
  chown kali:kali /home/kali/.vnc/passwd

  cat > /etc/systemd/system/vncserver@.service <<'EOF'
[Unit]
Description=TigerVNC Server on display :%i
After=network.target

[Service]
Type=forking
User=kali
PAMName=login
PIDFile=/home/kali/.vnc/%H:%i.pid
ExecStartPre=-/usr/bin/vncserver -kill :%i > /dev/null 2>&1
ExecStart=/usr/bin/vncserver :%i -geometry 1280x800 -depth 24 -localhost no
ExecStop=/usr/bin/vncserver -kill :%i

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable vncserver@1.service
fi

echo "[4/11] Install Wazuh agent"
if ! dpkg -s wazuh-agent >/dev/null 2>&1; then
  curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
  echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
  apt-get update -y
  apt-get install -y wazuh-agent
fi

# Configure Wazuh placeholders
WAZUH_CONF="/var/ossec/etc/ossec.conf"
if [[ -f "$WAZUH_CONF" ]]; then
  sed -i 's|<address>[^<]*</address>|<address>__WAZUH_MANAGER__</address>|' "$WAZUH_CONF" || true
  
  if ! grep -q "CAPSTONE_USERSTACK_LOGS" "$WAZUH_CONF"; then
    perl -0777 -i -pe 's#</ossec_config>#  \n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/opt/capstone-userstack/logs/nginx/access.log</location>\n  </localfile>\n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/opt/capstone-userstack/logs/nginx/error.log</location>\n  </localfile>\n  <localfile>\n    <log_format>json</log_format>\n    <location>/opt/capstone-userstack/logs/modsecurity/modsec_audit.log</location>\n  </localfile>\n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/opt/capstone-userstack/logs/apache/access.log</location>\n  </localfile>\n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/opt/capstone-userstack/logs/apache/error.log</location>\n  </localfile>\n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/opt/capstone-userstack/logs/mysql/error.log</location>\n  </localfile>\n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/opt/capstone-userstack/logs/postgres/postgresql.log</location>\n  </localfile>\n</ossec_config>#s' "$WAZUH_CONF"
  fi
fi

systemctl stop wazuh-agent || true
systemctl disable wazuh-agent || true

echo "[5/11] Helper: set Wazuh manager IP later"
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

echo "[6/11] Install capstone userstack files"
if [[ ! -d "$USERSTACK_SRC" ]]; then
  echo "Missing $USERSTACK_SRC" >&2
  exit 1
fi
rm -rf "$USERSTACK_DST"
mkdir -p "$USERSTACK_DST"
cp -a "$USERSTACK_SRC"/. "$USERSTACK_DST"/

mkdir -p \
  "$USERSTACK_DST/logs/nginx" \
  "$USERSTACK_DST/logs/modsecurity" \
  "$USERSTACK_DST/logs/apache" \
  "$USERSTACK_DST/logs/mysql" \
  "$USERSTACK_DST/logs/postgres" \
  "$USERSTACK_DST/logs/juiceshop"

if [[ -f "$USERSTACK_DST/.env.example" && ! -f "$USERSTACK_DST/.env" ]]; then
  cp "$USERSTACK_DST/.env.example" "$USERSTACK_DST/.env"
fi

chmod +x "$USERSTACK_DST/scripts"/*.sh || true
if [[ -d "$USERSTACK_DST/nginx-love/scripts" ]]; then
  chmod +x "$USERSTACK_DST/nginx-love/scripts"/*.sh || true
fi
# Normalize line endings for shell scripts to avoid CRLF issues
find "$USERSTACK_DST" -type f -name "*.sh" -exec sed -i 's/\r$//' {} +

echo "[7/11] Deploy nginx-love"
if [[ ! -f "$USERSTACK_DST/nginx-love/scripts/deploy.sh" ]]; then
  echo "Missing $USERSTACK_DST/nginx-love/scripts/deploy.sh" >&2
  exit 1
fi
bash "$USERSTACK_DST/nginx-love/scripts/deploy.sh"

echo "[8/11] Create systemd service: capstone-userstack"
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

echo "[9/11] Create systemd service: nginx-love-start"
cat > /usr/local/bin/nginx-love-start <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

start_if_exists() {
  local svc="$1"
  if systemctl list-unit-files "$svc" --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "$svc"; then
    systemctl start "$svc"
  else
    echo "Skipping start $svc (unit not found)"
  fi
}

if systemctl list-unit-files docker.service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx docker.service; then
  systemctl start docker.service
fi

if command -v docker >/dev/null 2>&1; then
  docker start nginx-love-postgres >/dev/null 2>&1 || true
fi

start_if_exists nginx-love-backend.service
start_if_exists nginx-love-frontend.service
start_if_exists nginx.service
EOF
chmod +x /usr/local/bin/nginx-love-start

cat > /etc/systemd/system/nginx-love-start.service <<'EOF'
[Unit]
Description=Ensure nginx-love services are running
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nginx-love-start

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nginx-love-start.service

echo "[10/11] Pre-pull/build docker images"
if command -v docker >/dev/null 2>&1; then
  (
    cd "$USERSTACK_DST"
    docker compose pull || true
    docker compose build --pull || true
  ) || true
  systemctl stop capstone-userstack.service || true
else
  echo "Skipping docker compose pre-pull (docker not installed)"
fi

echo "[11/11] Optional: inject SSH public key"
if [[ -n "${PACKER_SSH_PUBLIC_KEY:-}" && -d /home/kali ]]; then
  install -d -m 0700 -o kali -g kali /home/kali/.ssh
  echo "$PACKER_SSH_PUBLIC_KEY" > /home/kali/.ssh/authorized_keys
  chown kali:kali /home/kali/.ssh/authorized_keys
  chmod 0600 /home/kali/.ssh/authorized_keys
fi

echo "[DONE] Cleanup"
rm -rf /tmp/capstone-userstack /tmp/scripts || true
apt-get autoremove -y || true
apt-get clean
rm -rf /var/lib/apt/lists/* || true

