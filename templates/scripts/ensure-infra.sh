#!/usr/bin/env bash
#
# CI/CD Blueprint - deploy oncesi altyapi hazirligi (DB migration vb.)
# CI/CD Blueprint - pre-deploy infra prep (DB migrations, etc.)
#
# Blue-green sirasi / order:
#   1) ensure-infra (bu script) — geriye uyumlu migration
#   2) idle renge yayin / publish to idle
#   3) restart + health (socket)
#   4) switch (nginx reload)
#
# production-deploy.yml icinde RUN_ENSURE_INFRA=true ile acilir.
# Enable in production-deploy.yml with Variable RUN_ENSURE_INFRA=true.
#
# Gerekli (remote) / Required (remote):
#   SSH_HOST, SSH_USER, SSH_PRIVATE_KEY, SSH_KNOWN_HOSTS
#
# Kullanim / Usage:
#   1) ensure_infra_local / ensure_infra_remote fonksiyonlarini duzenleyin.
#   2) GitHub Variable: RUN_ENSURE_INFRA=true
#   3) Deploy calistirin.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_TARGET="${DEPLOY_TARGET:-local}"

ensure_infra_local() {
  # --- PROJE OZEL / PROJECT-SPECIFIC: asagiyi duzenleyin / edit below ---
  #
  # Ornek EF Core (runner'da SDK var, DB'ye dogrudan baglanir) / Example EF Core:
  #   dotnet ef database update \
  #     --project path/to/Infrastructure.csproj \
  #     --startup-project path/to/Web.csproj
  #
  echo "HATA / ERROR: ensure-infra.sh yapilandirilmamis / not configured."
  echo "  scripts/ensure-infra.sh -> ensure_infra_local() fonksiyonunu duzenleyin."
  echo "  Duzenlemeden RUN_ENSURE_INFRA=true yapmayin."
  echo "  Do not set RUN_ENSURE_INFRA=true before customizing this file."
  exit 1
}

ensure_infra_remote() {
  # --- PROJE OZEL / PROJECT-SPECIFIC: asagiyi duzenleyin / edit below ---
  #
  # Ornek A (onerilen): migration runner'da, DB uzakta — sunucuda SDK gerekmez /
  # Example A (recommended): migrate on runner, DB remote — no SDK on server:
  #   dotnet ef database update --project ... --startup-project ...
  #
  # Ornek B: komutu uzak sunucuda calistir / run on remote server:
  #   remote_ssh 'cd /opt/myapp && dotnet ef database update ...'
  #
  echo "HATA / ERROR: ensure-infra.sh yapilandirilmamis / not configured."
  echo "  scripts/ensure-infra.sh -> ensure_infra_remote() fonksiyonunu duzenleyin."
  echo "  Duzenlemeden RUN_ENSURE_INFRA=true yapmayin."
  echo "  Do not set RUN_ENSURE_INFRA=true before customizing this file."
  exit 1
}

case "$DEPLOY_TARGET" in
  remote)
    # shellcheck source=ssh-remote.sh
    source "${SCRIPT_DIR}/ssh-remote.sh"
    ssh_remote_init
    ensure_infra_remote
    ;;
  local|*)
    ensure_infra_local
    ;;
esac
