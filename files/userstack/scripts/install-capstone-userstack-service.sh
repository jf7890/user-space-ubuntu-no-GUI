#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="${CAPSTONE_STACK_DIR:-/opt/capstone-userstack}"
SERVICE_NAME="capstone-userstack.service"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}"
ENV_FILE="${STACK_DIR}/.env"
ENV_EXAMPLE="${STACK_DIR}/.env.example"

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be run as root" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not installed; install Docker first" >&2
  exit 1
fi

if [[ ! -f "${STACK_DIR}/docker-compose.yml" ]]; then
  echo "Missing ${STACK_DIR}/docker-compose.yml" >&2
  exit 1
fi

if systemctl list-unit-files docker.service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx docker.service; then
  systemctl enable --now docker.service
fi

if [[ -f "${ENV_EXAMPLE}" && ! -f "${ENV_FILE}" ]]; then
  cp "${ENV_EXAMPLE}" "${ENV_FILE}"
fi

get_primary_ip() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')" || true
  if [[ -z "$ip" ]]; then
    ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)" || true
  fi
  echo "$ip"
}

PRIMARY_IP="$(get_primary_ip)"
if [[ -n "${PRIMARY_IP}" && -f "${ENV_FILE}" ]]; then
  CORS_ORIGIN_VALUE="CORS_ORIGIN=\"http://localhost:8080,http://localhost:5173,http://${PRIMARY_IP}:8080\""
  VITE_API_URL_VALUE="VITE_API_URL=http://${PRIMARY_IP}:3001/api"

  if grep -q '^CORS_ORIGIN=' "${ENV_FILE}"; then
    sed -i "s|^CORS_ORIGIN=.*|${CORS_ORIGIN_VALUE}|" "${ENV_FILE}"
  else
    echo "${CORS_ORIGIN_VALUE}" >> "${ENV_FILE}"
  fi

  if grep -q '^VITE_API_URL=' "${ENV_FILE}"; then
    sed -i "s|^VITE_API_URL=.*|${VITE_API_URL_VALUE}|" "${ENV_FILE}"
  else
    echo "${VITE_API_URL_VALUE}" >> "${ENV_FILE}"
  fi
fi

cat > "${UNIT_PATH}" <<EOF
[Unit]
Description=Capstone user lab stack (docker compose)
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${STACK_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl start "${SERVICE_NAME}"
