#!/usr/bin/env bash
set -euo pipefail

# Script chạy bởi quyền root (qua Packer)

USERSTACK_SRC="/tmp/capstone-userstack"
USERSTACK_DST="/opt/capstone-userstack"
export DEBIAN_FRONTEND=noninteractive

echo "[1/9] Fix Sources List & Update"
# Vì tắt mirror trong preseed, ta phải thêm lại repo online để cài gói mới
cat > /etc/apt/sources.list <<EOF
deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
# deb-src http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
EOF

apt-get update -y

echo "[2/9] Install Cloud-init, VNC & Docker"
# Cài thêm các gói thiếu vì không cài trong Preseed
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release jq unzip \
  cloud-init tigervnc-standalone-server dbus-x11 \
  kali-tools-web

# Docker CE theo hướng dẫn chính thức (Debian/Kali)
# Kali reports VERSION_CODENAME=kali-rolling; Docker repo follows Debian codenames.
DOCKER_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
if [[ "$DOCKER_CODENAME" == "kali-rolling" ]]; then
  DOCKER_CODENAME="bookworm"
fi

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${DOCKER_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y --no-install-recommends \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

# Fix Cloud-init services
systemctl enable cloud-init-local cloud-init config cloud-final

# Allow 'kali' user to run docker
if id kali >/dev/null 2>&1; then
  usermod -aG docker kali || true
fi

echo "[3/9] Configure VNC (XFCE)"
# Thiết lập thư mục và password VNC cho user kali
mkdir -p /home/kali/.vnc
chown kali:kali /home/kali/.vnc
chmod 700 /home/kali/.vnc

# Tạo file xstartup để chạy XFCE
cat > /home/kali/.vnc/xstartup <<EOF
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export SHELL=/bin/bash
startxfce4 &
EOF
chmod 755 /home/kali/.vnc/xstartup
chown kali:kali /home/kali/.vnc/xstartup

# Set password VNC là 'kali1234'
su - kali -c "printf \"kali1234\n\" | vncpasswd -f > ~/.vnc/passwd"
chmod 600 /home/kali/.vnc/passwd
chown kali:kali /home/kali/.vnc/passwd

# Tạo Systemd service cho VNC
cat > /etc/systemd/system/vncserver@.service <<EOF
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

echo "[4/9] Install Wazuh agent"
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

echo "[5/9] Helper: set Wazuh manager IP later"
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

echo "[6/9] Install capstone userstack files"
rm -rf "$USERSTACK_DST"
mkdir -p "$USERSTACK_DST"
cp -a "$USERSTACK_SRC"/* "$USERSTACK_DST"/

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

echo "[7/9] Create systemd service: capstone-userstack"
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

echo "[8/9] Pre-pull/build docker images"
(
  cd "$USERSTACK_DST"
  docker compose pull || true
  docker compose build --pull || true
) || true
systemctl stop capstone-userstack.service || true

echo "[9/9] Optional: inject SSH public key"
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
