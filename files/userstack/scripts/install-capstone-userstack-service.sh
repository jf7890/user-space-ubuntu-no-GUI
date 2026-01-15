#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="${CAPSTONE_STACK_DIR:-/opt/capstone-userstack}"
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
  systemctl enable --now docker.service >/dev/null
fi

if [[ -f "${ENV_EXAMPLE}" && ! -f "${ENV_FILE}" ]]; then
  cp "${ENV_EXAMPLE}" "${ENV_FILE}"
fi

cd "${STACK_DIR}"
docker compose up -d >/dev/null
