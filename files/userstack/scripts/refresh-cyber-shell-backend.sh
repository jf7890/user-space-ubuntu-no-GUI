#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="${CYBER_SHELL_BACKEND_DIR:-/opt/cyber-shell-backend}"
REPO_REF="${CYBER_SHELL_BACKEND_REPO_REF:-main}"

resolve_compose_file() {
  local stack_dir="$1"
  local candidate

  for candidate in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [[ -f "${stack_dir}/${candidate}" ]]; then
      printf '%s\n' "${stack_dir}/${candidate}"
      return 0
    fi
  done

  return 1
}

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

COMPOSE_FILE="$(resolve_compose_file "${STACK_DIR}")" || {
  echo "Missing docker compose file in ${STACK_DIR}; skipping refresh" >&2
  exit 0
}

if systemctl list-unit-files docker.service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx docker.service; then
  systemctl start docker.service >/dev/null 2>&1 || true
fi

git -C "${STACK_DIR}" pull --ff-only origin "${REPO_REF}"

if [[ -f "${STACK_DIR}/.env.example" && ! -f "${STACK_DIR}/.env" ]]; then
  cp "${STACK_DIR}/.env.example" "${STACK_DIR}/.env"
fi

cd "${STACK_DIR}"
docker compose -f "${COMPOSE_FILE}" pull
docker compose -f "${COMPOSE_FILE}" up -d --build
