#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="${REDTEAM_ENGINE_DIR:-${REDTEAM_ATTACK_ENGINE_DIR:-/opt/Redteam-Attack-Engine-Minimal}}"
REPO_REF="${REDTEAM_ENGINE_REPO_REF:-main}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be run as root" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git not installed; skipping refresh" >&2
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not installed; skipping refresh" >&2
  exit 0
fi

if [[ ! -d "${STACK_DIR}/.git" ]]; then
  echo "Missing git repository at ${STACK_DIR}; skipping refresh" >&2
  exit 0
fi

if [[ ! -f "${STACK_DIR}/docker-compose.yml" && ! -f "${STACK_DIR}/docker-compose.yaml" && ! -f "${STACK_DIR}/compose.yml" && ! -f "${STACK_DIR}/compose.yaml" ]]; then
  echo "Missing docker compose file in ${STACK_DIR}; skipping refresh" >&2
  exit 0
fi

if systemctl list-unit-files docker.service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx docker.service; then
  systemctl start docker.service >/dev/null 2>&1 || true
fi

git -C "${STACK_DIR}" pull --ff-only origin "${REPO_REF}"

if [[ -f "${STACK_DIR}/.env.example" && ! -f "${STACK_DIR}/.env" ]]; then
  cp "${STACK_DIR}/.env.example" "${STACK_DIR}/.env"
fi

cd "${STACK_DIR}"
docker compose pull
docker compose up -d
