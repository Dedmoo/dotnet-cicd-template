#!/usr/bin/env bash
#
# CI/CD Blueprint - cok servisli deploy/rollback yardimcisi
# CI/CD Blueprint - multi-service deploy/rollback helper
#
# DEPLOY_TARGET:
#   local  - runner ve uygulama ayni makinede (varsayilan / default)
#   remote - uzak Linux sunucuya SSH ile deploy / deploy via SSH to remote Linux
#
#   SERVICES formati / format (her satir bir servis / one service per line):
#   name|csproj|deploy_dir|service_name|health_url
#
# Uzak deploy icin ek / For remote deploy also:
#   SSH_HOST, SSH_USER, SSH_PRIVATE_KEY (secret)
#   SSH_PORT (opsiyonel / optional), SSH_KNOWN_HOSTS (opsiyonel / optional)
#
# Kullanim / Usage:
#   bash pipeline.sh <backup|publish-source|deploy-artifacts|write-env|write-info|restart|health|rollback>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-Release}"
DEPLOY_TARGET="${DEPLOY_TARGET:-local}"

# shellcheck source=ssh-remote.sh
source "${SCRIPT_DIR}/ssh-remote.sh"
ssh_remote_init

services_lines() {
  printf '%s\n' "${SERVICES:?SERVICES ortam degiskeni tanimli degil / SERVICES env not set}" \
    | grep -vE '^\s*(#.*)?$'
}

field() {
  printf '%s' "$1" | cut -d'|' -f"$2" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

target_dir_exists() {
  local dd="$1"
  if is_remote; then
    remote_path_exists "$dd"
  else
    [ -d "$dd" ]
  fi
}

target_backup_one() {
  local dd="$1"
  if is_remote; then
    remote_sudo "if [ -d '$dd' ]; then rm -rf '${dd}.previous'; cp -a '$dd' '${dd}.previous'; fi"
  else
    if [ -d "$dd" ]; then
      rm -rf "${dd}.previous"
      cp -a "$dd" "${dd}.previous"
    fi
  fi
}

target_publish_dir() {
  local staging="$1"
  local dd="$2"
  if is_remote; then
    remote_sudo "mkdir -p '$dd'"
    remote_rsync "${staging}/" "${dd}/"
    remote_sudo "chown -R '${SSH_USER}':'${SSH_USER}' '$dd'"
  else
    mkdir -p "$dd"
    rsync -a --delete "${staging}/" "${dd}/"
  fi
}

target_write_env_one() {
  local dd="$1"
  local content="$2"
  if is_remote; then
    remote_sudo "mkdir -p '$dd'"
    local tmp="/tmp/cicd-env-$$"
    remote_write_file "$content" "$tmp" 600
    remote_sudo "mv '$tmp' '${dd}/.env' && chmod 600 '${dd}/.env' && chown '${SSH_USER}:${SSH_USER}' '${dd}/.env'"
  else
    [ -d "$dd" ] || return 0
    printf '%s\n' "$content" > "${dd}/.env"
    chmod 600 "${dd}/.env"
  fi
}

target_write_info_one() {
  local dd="$1"
  local info="$2"
  if is_remote; then
    remote_sudo "mkdir -p '$dd'"
    remote_write_file "$info" "${dd}/.deploy-info" 644
  else
    [ -d "$dd" ] || return 0
    printf '%s' "$info" > "${dd}/.deploy-info"
  fi
}

target_restart_one() {
  local dd="$1"
  local svc="$2"
  if is_remote; then
    remote_sudo "pkill -f 'dotnet ${dd}' || true; sleep 1; systemctl restart '${svc}'"
  else
    pkill -f "dotnet ${dd}" || true
    sleep 1
    systemctl restart "$svc"
  fi
}

target_rollback_one() {
  local dd="$1"
  local svc="$2"
  if is_remote; then
    remote_sudo "if [ -d '${dd}.previous' ]; then pkill -f 'dotnet ${dd}' || true; sleep 1; rm -rf '$dd'; cp -a '${dd}.previous' '$dd'; systemctl restart '${svc}'; else exit 1; fi"
  else
    if [ -d "${dd}.previous" ]; then
      pkill -f "dotnet ${dd}" || true
      sleep 1
      rm -rf "$dd"
      cp -a "${dd}.previous" "$dd"
      systemctl restart "$svc"
    else
      return 1
    fi
  fi
}

cmd_backup() {
  while IFS= read -r line; do
    local dd; dd="$(field "$line" 3)"
    if target_dir_exists "$dd"; then
      target_backup_one "$dd"
      echo "yedeklendi / backed up: $dd -> ${dd}.previous"
    else
      echo "yedeklenecek surum yok / nothing to back up: $dd"
    fi
  done < <(services_lines)
}

cmd_publish_source() {
  while IFS= read -r line; do
    local csproj dd staging
    csproj="$(field "$line" 2)"
    dd="$(field "$line" 3)"
    staging="$(mktemp -d)"
    dotnet publish "$csproj" --configuration "$CONFIG" --output "$staging" /p:UseSharedCompilation=false
    target_publish_dir "$staging" "$dd"
    rm -rf "$staging"
    echo "yayinlandi (kaynaktan) / published (from source): $csproj -> $dd"
  done < <(services_lines)
}

cmd_deploy_artifacts() {
  : "${ARTIFACT_ROOT:?ARTIFACT_ROOT tanimli degil / ARTIFACT_ROOT not set}"
  while IFS= read -r line; do
    local name dd src
    name="$(field "$line" 1)"
    dd="$(field "$line" 3)"
    src="${ARTIFACT_ROOT}/${name}"
    if [ ! -d "$src" ]; then
      echo "artifact bulunamadi / artifact not found: $src"
      exit 1
    fi
    target_publish_dir "$src" "$dd"
    echo "yayinlandi (artifact) / published (artifact): $src -> $dd"
  done < <(services_lines)
}

cmd_write_env() {
  if [ -z "${APP_ENV:-}" ]; then
    echo "APP_ENV bos, atlaniyor / empty, skipped"
    return 0
  fi
  while IFS= read -r line; do
    local dd; dd="$(field "$line" 3)"
    target_write_env_one "$dd" "$APP_ENV"
    echo "gizli ortam yazildi / secret env written: ${dd}/.env"
  done < <(services_lines)
}

cmd_write_info() {
  while IFS= read -r line; do
    local dd info
    dd="$(field "$line" 3)"
    info="deploy_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
commit=${GIT_SHA:-unknown}
deployed_by=${DEPLOYED_BY:-unknown}
deploy_target=${DEPLOY_TARGET}
note=${DEPLOY_NOTE:-}"
    target_write_info_one "$dd" "$info"
    echo "deploy bilgisi yazildi / deploy info written: ${dd}/.deploy-info"
  done < <(services_lines)
}

cmd_restart() {
  while IFS= read -r line; do
    local dd svc
    dd="$(field "$line" 3)"
    svc="$(field "$line" 4)"
    target_restart_one "$dd" "$svc"
    echo "yeniden baslatildi / restarted: $svc"
  done < <(services_lines)
}

cmd_health() {
  local fail=0
  while IFS= read -r line; do
    local url
    url="$(field "$line" 5)"
    if ! bash "${SCRIPT_DIR}/verify-health.sh" "$url"; then
      fail=1
    fi
  done < <(services_lines)
  return "$fail"
}

cmd_rollback() {
  local fail=0
  while IFS= read -r line; do
    local dd svc
    dd="$(field "$line" 3)"
    svc="$(field "$line" 4)"
    if target_rollback_one "$dd" "$svc"; then
      echo "geri alindi / rolled back: ${dd}.previous -> $dd"
    else
      echo "geri alinacak surum yok / no previous release: ${dd}.previous"
      fail=1
    fi
  done < <(services_lines)
  return "$fail"
}

main() {
  local command="${1:-}"
  case "$command" in
    backup)           cmd_backup ;;
    publish-source)   cmd_publish_source ;;
    deploy-artifacts) cmd_deploy_artifacts ;;
    write-env)        cmd_write_env ;;
    write-info)       cmd_write_info ;;
    restart)          cmd_restart ;;
    health)           cmd_health ;;
    rollback)         cmd_rollback ;;
    *)
      echo "kullanim / usage: DEPLOY_TARGET=local|remote SERVICES=... bash pipeline.sh <command>"
      exit 1
      ;;
  esac
}

main "$@"
