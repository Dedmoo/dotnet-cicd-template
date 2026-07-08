#!/usr/bin/env bash
#
# CI/CD Blueprint - uzak sunucu SSH yardimcilari
# CI/CD Blueprint - remote server SSH helpers
#
# DEPLOY_TARGET=remote iken pipeline.sh tarafindan source edilir.
# Sourced by pipeline.sh when DEPLOY_TARGET=remote.
#
# Gerekli ortam degiskenleri / Required env:
#   SSH_HOST, SSH_USER, SSH_PRIVATE_KEY
# Opsiyonel / Optional: SSH_PORT (22), SSH_KNOWN_HOSTS

set -euo pipefail

SSH_PORT="${SSH_PORT:-22}"
SSH_KEY_FILE=""

is_remote() {
  [ "${DEPLOY_TARGET:-local}" = "remote" ]
}

ssh_remote_init() {
  if ! is_remote; then
    return 0
  fi

  : "${SSH_HOST:?SSH_HOST tanimli degil / not set}"
  : "${SSH_USER:?SSH_USER tanimli degil / not set}"
  : "${SSH_PRIVATE_KEY:?SSH_PRIVATE_KEY tanimli degil / not set}"

  if ! command -v ssh >/dev/null 2>&1; then
    echo "ssh bulunamadi / ssh not found"
    exit 1
  fi
  if ! command -v rsync >/dev/null 2>&1; then
    echo "rsync bulunamadi / rsync not found"
    exit 1
  fi

  SSH_KEY_FILE="$(mktemp)"
  printf '%s\n' "$SSH_PRIVATE_KEY" > "$SSH_KEY_FILE"
  chmod 600 "$SSH_KEY_FILE"

  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"

  if [ -n "${SSH_KNOWN_HOSTS:-}" ]; then
    printf '%s\n' "$SSH_KNOWN_HOSTS" >> "${HOME}/.ssh/known_hosts"
  else
    ssh-keyscan -p "$SSH_PORT" "$SSH_HOST" >> "${HOME}/.ssh/known_hosts" 2>/dev/null || true
  fi
  chmod 600 "${HOME}/.ssh/known_hosts" 2>/dev/null || true

  export SSH_TARGET="${SSH_USER}@${SSH_HOST}"
  export SSH_CMD=(ssh -i "$SSH_KEY_FILE" -p "$SSH_PORT" -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=15)
  export RSYNC_SSH="ssh -i ${SSH_KEY_FILE} -p ${SSH_PORT} -o StrictHostKeyChecking=yes -o BatchMode=yes"

  echo "SSH hazir / ready: ${SSH_TARGET} (port ${SSH_PORT})"
}

ssh_remote_cleanup() {
  if [ -n "$SSH_KEY_FILE" ] && [ -f "$SSH_KEY_FILE" ]; then
    rm -f "$SSH_KEY_FILE"
  fi
}

remote_ssh() {
  "${SSH_CMD[@]}" "$SSH_TARGET" "$@"
}

remote_sudo() {
  local cmd="$1"
  if [ -n "${SSH_SUDO_PASSWORD:-}" ]; then
    printf '%s\n' "$SSH_SUDO_PASSWORD" | "${SSH_CMD[@]}" "$SSH_TARGET" "sudo -S bash -c $(printf '%q' "$cmd")"
  else
    "${SSH_CMD[@]}" "$SSH_TARGET" "sudo bash -c $(printf '%q' "$cmd")"
  fi
}

remote_rsync() {
  local src="$1"
  local dest="$2"
  rsync -az --delete -e "$RSYNC_SSH" "${src}" "${SSH_TARGET}:${dest}"
}

remote_path_exists() {
  local path="$1"
  remote_ssh "[ -e '$path' ]"
}

remote_write_file() {
  local content="$1"
  local dest="$2"
  local mode="${3:-600}"
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$content" > "$tmp"
  rsync -az -e "$RSYNC_SSH" "$tmp" "${SSH_TARGET}:${dest}"
  rm -f "$tmp"
  remote_ssh "chmod '$mode' '$dest'"
}

trap ssh_remote_cleanup EXIT
