#!/usr/bin/env bash
set -euo pipefail

# Script chạy bởi quyền root (qua Packer)

USERSTACK_SRC="/tmp/capstone-userstack"
USERSTACK_DST="/opt/capstone-userstack"
export DEBIAN_FRONTEND=noninteractive

echo "[1/8] Fix Sources List & Update"
cat > /etc/apt/sources.list <<EOF
deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
# deb-src http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
EOF

apt-get update -y >/dev/null

echo "[2/8] Install Cloud-init, VNC & tools"
# Cài thêm các gói thiếu vì không cài trong Preseed
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg jq unzip npm \
  cloud-init tigervnc-standalone-server tigervnc-common tigervnc-tools dbus-x11 \
  git \
  nmap \
  sqlmap \
  nikto >/dev/null

echo "[2.1/8] Ensure kali login password"
if id kali >/dev/null 2>&1; then
  echo "kali:kali" | chpasswd >/dev/null
  passwd -u kali >/dev/null 2>&1 || true
  if [[ -d /home/kali ]]; then
    chown -R kali:kali /home/kali
  fi
else
  echo "Skipping password reset (user kali not found)"
fi

echo "[2.2/8] Ensure researcher user (restricted)"
RESEARCHER_USER="researcher"
RESEARCHER_PASSWORD="${RESEARCHER_PASSWORD:-researcher}"
if ! id "${RESEARCHER_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${RESEARCHER_USER}"
fi
echo "${RESEARCHER_USER}:${RESEARCHER_PASSWORD}" | chpasswd >/dev/null
passwd -u "${RESEARCHER_USER}" >/dev/null 2>&1 || true
if getent group sudo >/dev/null 2>&1; then
  deluser "${RESEARCHER_USER}" sudo >/dev/null 2>&1 || true
fi
if getent group docker >/dev/null 2>&1; then
  gpasswd -d "${RESEARCHER_USER}" docker >/dev/null 2>&1 || true
fi

# Docker CE (official)
DOCKER_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
if [[ "$DOCKER_CODENAME" == "kali-rolling" ]]; then
  DOCKER_CODENAME="bookworm"
fi

apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc >/dev/null 2>&1 || true
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${DOCKER_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null

# Enable cloud-init units that exist
for svc in cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service; do
  if systemctl list-unit-files "$svc" --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "$svc"; then
    systemctl enable "$svc" >/dev/null
  else
    echo "Skipping enable $svc (unit not found)"
  fi
done

if command -v docker >/dev/null 2>&1; then
  systemctl enable --now docker >/dev/null
  # Allow 'kali' user to run docker
  if id kali >/dev/null 2>&1; then
    usermod -aG docker kali || true
  fi
else
  echo "Skipping docker enable (docker not installed)"
fi

echo "[3/8] Configure VNC (XFCE)"
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

  systemctl daemon-reload >/dev/null
  systemctl enable vncserver@1.service >/dev/null
fi

echo "[4/8] Install Wazuh agent"
if ! dpkg -s wazuh-agent >/dev/null 2>&1; then
  curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
  echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
  apt-get update -y >/dev/null
  apt-get install -y wazuh-agent >/dev/null
fi

# Configure Wazuh agent config
WAZUH_CONF="/var/ossec/etc/ossec.conf"
USERSTACK_WAZUH_CONF="${USERSTACK_DST}/config/ossec.conf"
if [[ -f "$USERSTACK_WAZUH_CONF" ]]; then
  install -m 0644 "$USERSTACK_WAZUH_CONF" "$WAZUH_CONF"
fi

if [[ -n "${WAZUH_MANAGER:-}" && -f "$WAZUH_CONF" ]]; then
  sed -i "s|<address>[^<]*</address>|<address>${WAZUH_MANAGER}</address>|" "$WAZUH_CONF" || true
fi

systemctl stop wazuh-agent >/dev/null 2>&1 || true
systemctl disable wazuh-agent >/dev/null 2>&1 || true

echo "[5/8] Helper: set Wazuh manager IP later"
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
sed -i "s|<address>[^<]*</address>|<address>${mgr}</address>|" "$conf"
systemctl enable --now wazuh-agent
systemctl restart wazuh-agent
systemctl status wazuh-agent --no-pager
EOF
chmod +x /usr/local/bin/wazuh-set-manager

echo "[6/8] Install capstone userstack files"
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
  "$USERSTACK_DST/logs/postgres"

if [[ -f "$USERSTACK_DST/.env.example" && ! -f "$USERSTACK_DST/.env" ]]; then
  cp "$USERSTACK_DST/.env.example" "$USERSTACK_DST/.env"
fi

chmod +x "$USERSTACK_DST/scripts"/*.sh || true

if command -v systemctl >/dev/null 2>&1; then
  cat > /etc/systemd/system/capstone-userstack-env.service <<EOF
[Unit]
Description=Update capstone userstack env and hosts
Wants=network-online.target
After=network-online.target
ConditionPathExists=${USERSTACK_DST}/scripts/update-capstone-userstack-env.sh

[Service]
Type=oneshot
Environment=CAPSTONE_STACK_DIR=${USERSTACK_DST}
ExecStart=/bin/sh -c '${USERSTACK_DST}/scripts/update-capstone-userstack-env.sh >/dev/null 2>&1 || true'

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload >/dev/null
  systemctl enable capstone-userstack-env.service >/dev/null
else
  echo "Skipping capstone userstack env service (systemd not available)"
fi

echo "[7/8] Start capstone userstack (docker compose)"
bash "$USERSTACK_DST/scripts/install-capstone-userstack-service.sh"

echo "[8/8] Optional: inject SSH public key"
if [[ -n "${PACKER_SSH_PUBLIC_KEY:-}" && -d /home/kali ]]; then
  install -d -m 0700 -o kali -g kali /home/kali/.ssh
  echo "$PACKER_SSH_PUBLIC_KEY" > /home/kali/.ssh/authorized_keys
  chown kali:kali /home/kali/.ssh/authorized_keys
  chmod 0600 /home/kali/.ssh/authorized_keys
fi

echo "[DONE] Cleanup"
rm -rf /tmp/capstone-userstack /tmp/scripts || true
apt-get autoremove -y >/dev/null 2>&1 || true
apt-get clean >/dev/null 2>&1
rm -rf /var/lib/apt/lists/* || true

