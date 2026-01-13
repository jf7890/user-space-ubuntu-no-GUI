#!/usr/bin/env bash
set -euo pipefail

# This script is intended to run as root (systemd first-boot).
# Comments are English-only by request.

export DEBIAN_FRONTEND=noninteractive

# Re-run as root if needed (e.g., SSH user is "kali")
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo -n -E bash "$0" "$@"
fi

MODE="${1:-run}"

if [[ "$MODE" != "--prepare" ]]; then
  LOG_FILE="/var/log/capstone-userstack-provision.log"
  mkdir -p /var/log
  if command -v tee >/dev/null 2>&1; then
    exec > >(tee -a "$LOG_FILE") 2>&1
  else
    exec >>"$LOG_FILE" 2>&1
  fi
  echo "=== $(date -Is) Starting capstone provisioning ==="
  echo "Log file: ${LOG_FILE}"
fi

if [[ "${CAPSTONE_DEBUG:-}" == "1" ]]; then
  set -x
fi

prepare_only() {
  local prepare_userstack_src="${PREPARE_USERSTACK_SRC:-/tmp/capstone-userstack-src}"
  local prepare_scripts_src="${PREPARE_SCRIPTS_SRC:-/tmp/capstone-scripts}"
  local pve_cfg="${PREPARE_PVE_CFG:-/tmp/99-pve.cfg}"
  local ssh_pub="${PACKER_SSH_PUBLIC_KEY:-${SSH_PUBLIC_KEY:-}}"

  echo "[PREPARE] Stage capstone assets"
  rm -rf /opt/capstone-userstack-src /opt/capstone-scripts
  mkdir -p /opt/capstone-userstack-src /opt/capstone-scripts

  if compgen -G "${prepare_userstack_src}/*" >/dev/null; then
    cp -a "${prepare_userstack_src}/." /opt/capstone-userstack-src/
  else
    echo "WARNING: No userstack files found in ${prepare_userstack_src}" >&2
  fi

  if compgen -G "${prepare_scripts_src}/*" >/dev/null; then
    cp -a "${prepare_scripts_src}/." /opt/capstone-scripts/
  else
    echo "WARNING: No scripts found in ${prepare_scripts_src}" >&2
  fi

  chmod +x /opt/capstone-scripts/*.sh 2>/dev/null || true

  if [[ -f "$pve_cfg" ]]; then
    mkdir -p /etc/cloud/cloud.cfg.d 2>/dev/null || true
    cp "$pve_cfg" /etc/cloud/cloud.cfg.d/99-pve.cfg
  fi

  cat > /etc/systemd/system/capstone-firstboot.service <<'EOF'
[Unit]
Description=Capstone first boot provisioning
Wants=network-online.target
After=network-online.target
ConditionPathExists=/opt/capstone-scripts/provision-kali-userstack.sh
ConditionPathExists=!/var/lib/capstone-userstack/provisioned

[Service]
Type=oneshot
ExecStart=/opt/capstone-scripts/provision-kali-userstack.sh
RemainAfterExit=yes
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload > /dev/null 2>&1 || true
  if [[ ! -f /var/lib/capstone-userstack/provisioned ]]; then
    systemctl enable capstone-firstboot.service > /dev/null 2>&1 || true
  else
    systemctl disable capstone-firstboot.service > /dev/null 2>&1 || true
  fi

  if [[ -z "$ssh_pub" ]]; then
    echo "ERROR: PACKER_SSH_PUBLIC_KEY is required for key-only SSH." >&2
    exit 1
  fi

  install -d -m 0700 -o kali -g kali /home/kali/.ssh
  printf '%s\n' "$ssh_pub" > /home/kali/.ssh/authorized_keys
  chown kali:kali /home/kali/.ssh/authorized_keys
  chmod 0600 /home/kali/.ssh/authorized_keys

  if [[ -f /etc/ssh/sshd_config ]]; then
    if grep -q '^#\?PermitRootLogin' /etc/ssh/sshd_config; then
      sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    else
      echo 'PermitRootLogin no' >> /etc/ssh/sshd_config
    fi
    if grep -q '^#\?PasswordAuthentication' /etc/ssh/sshd_config; then
      sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    else
      echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
    fi
  fi

  echo "[PREPARE] SSH hardening staged (applies on next boot)."

  # Restore safer sudo defaults (Packer uses NOPASSWD during build only).
  if id kali >/dev/null 2>&1; then
    usermod -aG sudo kali >/dev/null 2>&1 || true
  fi
  if [[ -f /etc/sudoers.d/kali ]]; then
    cat > /etc/sudoers.d/kali <<'EOF'
kali ALL=(ALL:ALL) ALL
EOF
    chmod 440 /etc/sudoers.d/kali
    chown root:root /etc/sudoers.d/kali
  fi

  rm -rf "$prepare_userstack_src" "$prepare_scripts_src" 2>/dev/null || true
  rm -f /root/.ssh/authorized_keys 2>/dev/null || true
  rm -f /etc/ssh/ssh_host_* 2>/dev/null || true
  truncate -s 0 /etc/machine-id 2>/dev/null || true
  rm -f /var/lib/dbus/machine-id 2>/dev/null || true
  find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true
  rm -f /root/.bash_history /home/kali/.bash_history 2>/dev/null || true
  rm -rf /var/lib/apt/lists/* 2>/dev/null || true
  if command -v cloud-init >/dev/null 2>&1; then
    cloud-init clean --logs > /dev/null 2>&1 || true
  fi
  sync || true

  echo "[PREPARE] Done."
}

if [[ "$MODE" == "--prepare" ]]; then
  prepare_only
  exit 0
fi

if [[ "$MODE" != "run" && "$MODE" != "" ]]; then
  echo "Usage: $0 [--prepare]" >&2
  exit 1
fi

PROVISION_MARKER="/var/lib/capstone-userstack/provisioned"
if [[ -f "$PROVISION_MARKER" ]]; then
  echo "[SKIP] Capstone provisioning already completed."
  exit 0
fi

USERSTACK_SRC="/opt/capstone-userstack-src"
USERSTACK_DST="/opt/capstone-userstack"
WAZUH_MANAGER="${WAZUH_MANAGER:-172.16.99.11}"

KALI_SHADOW_HASH=""
if id kali >/dev/null 2>&1; then
  KALI_SHADOW_HASH="$(getent shadow kali 2>/dev/null | cut -d: -f2 || true)"
  if [[ -n "$KALI_SHADOW_HASH" ]]; then
    install -d -m 0700 /var/lib/capstone-userstack
    printf '%s' "$KALI_SHADOW_HASH" > /var/lib/capstone-userstack/kali.shadow.hash
    chmod 0600 /var/lib/capstone-userstack/kali.shadow.hash
  fi
fi

# Cloud-init can lock the default user when no password is provided via metadata.
# Write our defaults early so they're present even if cloud-init services start during package install.
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-capstone-login.cfg <<'EOF'
#cloud-config
system_info:
  default_user:
    name: kali
    lock_passwd: false
chpasswd:
  expire: false
ssh_pwauth: false
EOF

echo "[1/10] Configure apt sources"
cat > /etc/apt/sources.list <<'EOF'
deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
# deb-src http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
EOF

echo "[2/10] Apt update + base packages"
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release jq unzip \
  qemu-guest-agent \
  cloud-init \
  tigervnc-standalone-server dbus-x11

resolve_docker_bin() {
  local docker_bin
  docker_bin="$(type -P docker 2>/dev/null || true)"
  if [[ -z "$docker_bin" ]]; then
    docker_bin="$(command -v docker 2>/dev/null || true)"
  fi
  if [[ -z "$docker_bin" ]]; then
    for candidate in /usr/bin/docker /usr/local/bin/docker /bin/docker; do
      if [[ -x "$candidate" ]]; then
        docker_bin="$candidate"
        break
      fi
    done
  fi
  printf '%s' "$docker_bin"
}

select_docker_repo_codename() {
  local detected candidates=() seen chosen
  detected="$(
    . /etc/os-release
    printf '%s\n%s\n' "${DEBIAN_CODENAME:-}" "${VERSION_CODENAME:-}"
  )"
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    [[ "$c" == kali-* ]] && continue
    candidates+=("$c")
  done <<<"$detected"

  candidates+=("bookworm" "bullseye")

  chosen=""
  for c in "${candidates[@]}"; do
    if [[ -n "${seen:-}" ]] && [[ ",${seen}," == *",${c},"* ]]; then
      continue
    fi
    seen="${seen:+$seen,}${c}"
    if curl -fsSL "https://download.docker.com/linux/debian/dists/${c}/Release" >/dev/null 2>&1; then
      chosen="$c"
      break
    fi
  done

  if [[ -z "$chosen" ]]; then
    chosen="bookworm"
  fi
  printf '%s' "$chosen"
}

install_docker_engine() {
  local codename arch docker_list

  if [[ -n "$(resolve_docker_bin)" ]]; then
    return 0
  fi

  echo "Installing Docker Engine (Docker upstream repo)"
  # https://docs.docker.com/engine/install/debian/

  docker_list="/etc/apt/sources.list.d/docker.list"

  # Remove potentially conflicting distro packages (best-effort).
  apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc >/dev/null 2>&1 || true

  install -m 0755 -d /etc/apt/keyrings
  if ! curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc; then
    echo "WARNING: Failed to download Docker GPG key." >&2
    return 1
  fi
  chmod a+r /etc/apt/keyrings/docker.asc

  codename="$(select_docker_repo_codename)"
  echo "Docker repo codename: ${codename}"

  arch="$(dpkg --print-architecture)"
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${codename} stable" \
    > "$docker_list"

  if ! apt-get update -y; then
    echo "WARNING: Docker upstream apt repo update failed." >&2
    rm -f "$docker_list" >/dev/null 2>&1 || true
    return 1
  fi

  if ! apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    echo "WARNING: Docker upstream packages failed to install." >&2
    rm -f "$docker_list" >/dev/null 2>&1 || true
    return 1
  fi

  if [[ -z "$(resolve_docker_bin)" ]]; then
    echo "WARNING: Docker installed but docker binary is still missing." >&2
    return 1
  fi
}

echo "[2/10] Install Docker Engine"
if ! install_docker_engine; then
  echo "WARNING: Docker upstream install failed; falling back to distro packages." >&2
  rm -f /etc/apt/sources.list.d/docker.list >/dev/null 2>&1 || true
  apt-get update -y
  apt-get install -y --no-install-recommends docker.io
fi
DOCKER_BIN="$(resolve_docker_bin)"
if [[ -z "$DOCKER_BIN" ]]; then
  echo "ERROR: docker is still missing after install attempts." >&2
  dpkg -l | grep -E '^(ii|hi)[[:space:]]+(docker|containerd|runc)' || true
  ls -la /usr/bin/docker* /usr/local/bin/docker* /bin/docker* 2>/dev/null || true
  exit 1
fi

# Optional tools (best-effort)
apt-get install -y --no-install-recommends kali-tools-web || true

echo "[2/10] Cloud-init defaults (preserve local login)"
if command -v cloud-init >/dev/null 2>&1; then
  mkdir -p /etc/cloud/cloud.cfg.d
  cat > /etc/cloud/cloud.cfg.d/99-capstone-login.cfg <<'EOF'
#cloud-config
system_info:
  default_user:
    name: kali
    lock_passwd: false
chpasswd:
  expire: false
ssh_pwauth: false
EOF
fi

# If cloud-init (or other tooling) locked the account, unlock it so console login works.
if id kali >/dev/null 2>&1; then
  # Restore the original shadow hash if cloud-init locked/overwrote it during install.
  if [[ -n "$KALI_SHADOW_HASH" ]]; then
    current_hash="$(getent shadow kali 2>/dev/null | cut -d: -f2 || true)"
    if [[ "$current_hash" != "$KALI_SHADOW_HASH" ]]; then
      usermod -p "$KALI_SHADOW_HASH" kali >/dev/null 2>&1 || true
    fi
  fi
  passwd -u kali >/dev/null 2>&1 || true
fi

echo "[2/10] Ensure kali login survives reboots"
cat > /usr/local/bin/capstone-ensure-kali-login <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if ! id kali >/dev/null 2>&1; then
  exit 0
fi

shadow_field="$(getent shadow kali 2>/dev/null | cut -d: -f2 || true)"
if [[ -z "$shadow_field" ]]; then
  exit 0
fi

# If cloud-init locks via "!<hash>", unlock while preserving the hash.
if [[ "$shadow_field" == '!$'* ]]; then
  passwd -u kali >/dev/null 2>&1 || true
  exit 0
fi

# If cloud-init replaced the hash entirely, restore from our saved hash (if present).
if [[ "$shadow_field" == '!'* || "$shadow_field" == '*'* ]]; then
  saved="/var/lib/capstone-userstack/kali.shadow.hash"
  if [[ -f "$saved" ]]; then
    saved_hash="$(cat "$saved" 2>/dev/null || true)"
    if [[ "$saved_hash" == '$'* ]]; then
      usermod -p "$saved_hash" kali >/dev/null 2>&1 || true
      passwd -u kali >/dev/null 2>&1 || true
    fi
  fi
fi
EOF
chmod +x /usr/local/bin/capstone-ensure-kali-login

cat > /etc/systemd/system/capstone-ensure-kali-login.service <<'EOF'
[Unit]
Description=Ensure kali account remains loginable (cloud-init safe-guard)
After=cloud-final.service
Wants=cloud-final.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/capstone-ensure-kali-login

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload > /dev/null 2>&1 || true
systemctl enable capstone-ensure-kali-login.service > /dev/null 2>&1 || true

resolve_compose_cmd() {
  local docker_bin docker_compose_bin
  docker_bin="$(command -v docker || true)"
  if [[ -n "$docker_bin" ]] && "$docker_bin" compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("$docker_bin" "compose")
    return 0
  fi

  docker_compose_bin="$(command -v docker-compose || true)"
  if [[ -n "$docker_compose_bin" ]]; then
    COMPOSE_CMD=("$docker_compose_bin")
    return 0
  fi

  return 1
}

install_compose_from_apt() {
  apt-get install -y --no-install-recommends docker-compose-plugin || true
  apt-get install -y --no-install-recommends docker-compose || true
}

install_compose_from_github() {
  local arch version url plugin_dir plugin_path
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    armv7l) arch="armv7" ;;
    *) echo "Unsupported architecture for docker compose: ${arch}" >&2; return 1 ;;
  esac

  version="$(curl -fsSL https://api.github.com/repos/docker/compose/releases/latest | jq -r '.tag_name' 2>/dev/null || true)"
  if [[ -z "$version" || "$version" == "null" ]]; then
    version="v2.27.1"
  fi

  url="https://github.com/docker/compose/releases/download/${version}/docker-compose-linux-${arch}"
  plugin_dir="/usr/local/lib/docker/cli-plugins"
  plugin_path="${plugin_dir}/docker-compose"

  mkdir -p "$plugin_dir"
  curl -fsSL "$url" -o "$plugin_path"
  chmod +x "$plugin_path"
  ln -sf "$plugin_path" /usr/local/bin/docker-compose
}

if ! resolve_compose_cmd; then
  install_compose_from_apt
fi
if ! resolve_compose_cmd; then
  echo "docker compose not found in apt; installing from GitHub releases (best-effort)"
  if ! install_compose_from_github; then
    echo "WARNING: Failed to install docker compose from GitHub; continuing." >&2
  fi
fi
if ! resolve_compose_cmd; then
  echo "ERROR: docker compose is required but could not be installed." >&2
  exit 1
fi

SYSTEMD_COMPOSE_CMD="${COMPOSE_CMD[*]}"
SYSTEMD_COMPOSE_START="${SYSTEMD_COMPOSE_CMD} up -d"
SYSTEMD_COMPOSE_STOP="${SYSTEMD_COMPOSE_CMD} down"

wait_for_docker() {
  local docker_bin
  docker_bin="${DOCKER_BIN:-$(resolve_docker_bin)}"
  if [[ -z "$docker_bin" ]]; then
    echo "ERROR: docker binary not found after install." >&2
    echo "PATH=${PATH}" >&2
    dpkg -l | grep -E '^(ii|hi)[[:space:]]+(docker|containerd|runc)' || true
    ls -la /usr/bin/docker* /usr/local/bin/docker* /bin/docker* 2>/dev/null || true
    return 1
  fi

  for _ in {1..60}; do
    if "$docker_bin" info >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "ERROR: Docker daemon is not ready (docker info failed)." >&2
  "$docker_bin" info || true
  return 1
}

echo "[3/10] Enable core services"
systemctl enable --now qemu-guest-agent > /dev/null 2>&1 || true
systemctl enable --now docker > /dev/null 2>&1 || true
wait_for_docker
if command -v cloud-init >/dev/null 2>&1; then
  systemctl enable cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service > /dev/null 2>&1 || true
  if [[ "${CAPSTONE_RUN_CLOUD_INIT:-}" == "1" ]]; then
    echo "Running cloud-init manually (CAPSTONE_RUN_CLOUD_INIT=1)"
    cloud-init clean --logs > /dev/null 2>&1 || true
    cloud-init init > /dev/null 2>&1 || true
    cloud-init modules --mode=config > /dev/null 2>&1 || true
    cloud-init modules --mode=final > /dev/null 2>&1 || true
  else
    echo "Skipping manual cloud-init run (set CAPSTONE_RUN_CLOUD_INIT=1 to force)."
  fi
fi

# Allow 'kali' user to run docker without sudo (if the user exists)
if id kali >/dev/null 2>&1; then
  usermod -aG docker kali || true
fi

echo "[4/10] Configure VNC (XFCE)"
if command -v vncserver >/dev/null 2>&1; then
  mkdir -p /home/kali/.vnc
  chown kali:kali /home/kali/.vnc
  chmod 700 /home/kali/.vnc

  cat > /home/kali/.vnc/xstartup <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export SHELL=/bin/bash
startxfce4 &
EOF
  chmod 755 /home/kali/.vnc/xstartup
  chown kali:kali /home/kali/.vnc/xstartup

  su - kali -c "printf \"kali1234\n\" | vncpasswd -f > ~/.vnc/passwd"
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

  systemctl daemon-reload > /dev/null 2>&1 || true
  systemctl enable vncserver@1.service > /dev/null 2>&1 || true
fi

echo "[5/10] Install Wazuh agent (optional; does not start until manager is set)"
# Wazuh provides a Debian/Ubuntu repo that also works for Kali (Debian-based).
# If external downloads are blocked, the install is skipped.
if ! dpkg -s wazuh-agent >/dev/null 2>&1; then
  if curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list \
    && apt-get update -y \
    && apt-get install -y wazuh-agent; then
    echo "Wazuh agent installed."
  else
    echo "Wazuh install failed; continuing without it." >&2
  fi
fi

# Keep the agent disabled by default; the manager address will be configured later.
WAZUH_CONF="/var/ossec/etc/ossec.conf"
if [[ -f "$WAZUH_CONF" ]]; then
  # Set a deterministic placeholder address
  sed -i 's|<address>[^<]*</address>|<address>__WAZUH_MANAGER__</address>|' "$WAZUH_CONF" || true

  # Add logcollector entries only once
  if ! grep -q "CAPSTONE_USERSTACK_LOGS" "$WAZUH_CONF"; then
    # Insert before closing tag (skip if perl is unavailable)
    if command -v perl >/dev/null 2>&1; then
      perl -0777 -i -pe 's#</ossec_config>#  <!-- CAPSTONE_USERSTACK_LOGS -->\n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/opt/capstone-userstack/logs/nginx/access.log</location>\n  </localfile>\n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/opt/capstone-userstack/logs/nginx/error.log</location>\n  </localfile>\n  <localfile>\n    <log_format>json</log_format>\n    <location>/opt/capstone-userstack/logs/modsecurity/modsec_audit.log</location>\n  </localfile>\n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/opt/capstone-userstack/logs/apache/access.log</location>\n  </localfile>\n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/opt/capstone-userstack/logs/apache/error.log</location>\n  </localfile>\n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/opt/capstone-userstack/logs/mysql/error.log</location>\n  </localfile>\n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/opt/capstone-userstack/logs/postgres/postgresql.log</location>\n  </localfile>\n</ossec_config>#s' "$WAZUH_CONF" || true
    else
      echo "perl not available; skipping Wazuh logcollector insertion." >&2
    fi
  fi
fi

systemctl stop wazuh-agent > /dev/null 2>&1 || true
systemctl disable wazuh-agent > /dev/null 2>&1 || true

echo "[6/10] Helper: set Wazuh manager address later"
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

# Replace the placeholder with the provided manager address
sed -i "s|<address>__WAZUH_MANAGER__</address>|<address>${mgr}</address>|" "$conf" || true

# Enable and start the agent without blocking the current SSH session
systemctl enable wazuh-agent > /dev/null 2>&1 || true
systemctl start --no-block wazuh-agent > /dev/null 2>&1 || true
systemctl restart wazuh-agent > /dev/null 2>&1 || true

# Best-effort status output without a pager
systemctl status wazuh-agent --no-pager > /dev/null 2>&1 || true
EOF
chmod +x /usr/local/bin/wazuh-set-manager

if [[ -n "$WAZUH_MANAGER" ]]; then
  cat > /etc/systemd/system/capstone-wazuh-manager.service <<EOF
[Unit]
Description=Configure Wazuh agent manager
Wants=network-online.target
After=network-online.target
ConditionPathExists=/var/ossec/etc/ossec.conf

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wazuh-set-manager ${WAZUH_MANAGER}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload > /dev/null 2>&1 || true
  systemctl enable capstone-wazuh-manager.service > /dev/null 2>&1 || true
  /usr/local/bin/wazuh-set-manager "${WAZUH_MANAGER}" || true
fi

echo "[7/10] Install capstone userstack files"
rm -rf "$USERSTACK_DST"
mkdir -p "$USERSTACK_DST"
if [[ ! -d "$USERSTACK_SRC" ]]; then
  echo "ERROR: Userstack source directory missing: $USERSTACK_SRC" >&2
  exit 1
fi
cp -a "$USERSTACK_SRC"/. "$USERSTACK_DST"/
if [[ ! -f "$USERSTACK_DST/docker-compose.yml" ]]; then
  echo "ERROR: Missing $USERSTACK_DST/docker-compose.yml (userstack assets were not staged)." >&2
  exit 1
fi

# Ensure log directories exist
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

chmod +x "$USERSTACK_DST/scripts"/*.sh 2>/dev/null || true

echo "[8/10] Create systemd service: capstone-userstack"
cat > /etc/systemd/system/capstone-userstack.service <<EOF
[Unit]
Description=Capstone user lab stack (DVWA + JuiceShop + nginx-love)
Wants=network-online.target docker.service
Requires=docker.service
After=network-online.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/capstone-userstack
ExecStartPre=/bin/bash -lc 'for _ in {1..60}; do [ -S /var/run/docker.sock ] && exit 0; sleep 1; done; echo "docker.sock not ready" >&2; exit 1'
ExecStart=${SYSTEMD_COMPOSE_START}
ExecStop=${SYSTEMD_COMPOSE_STOP}
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload > /dev/null 2>&1 || true
systemctl enable capstone-userstack.service > /dev/null 2>&1 || true

echo "[9/10] Pre-pull/build docker images (best-effort)"
# Avoid failing the whole provisioning if a registry is down.
(
  cd "$USERSTACK_DST"
  "${COMPOSE_CMD[@]}" pull || true
  "${COMPOSE_CMD[@]}" build --pull || true
) || true

echo "[9/10] Start userstack"
systemctl start capstone-userstack.service
systemctl is-active --quiet capstone-userstack.service

for name in dvwa juiceshop nginx-love-backend nginx-love-frontend; do
  if ! docker ps --format '{{.Names}}' | grep -qx "$name"; then
    echo "ERROR: Expected container is not running: ${name}" >&2
    docker ps -a || true
    exit 1
  fi
done

echo "[10/10] Finalize"
apt-get autoremove -y > /dev/null 2>&1 || true
apt-get clean > /dev/null 2>&1 || true
rm -rf /var/lib/apt/lists/* >/dev/null 2>&1 || true
mkdir -p "$(dirname "$PROVISION_MARKER")"
touch "$PROVISION_MARKER"
systemctl disable capstone-firstboot.service > /dev/null 2>&1 || true

echo "DONE: userstack provisioned (docker + wazuh + nginx-love)."
