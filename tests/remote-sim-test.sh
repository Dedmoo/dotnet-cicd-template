#!/usr/bin/env bash
# Uzak deploy tam akis simulasyonu: SSH + rsync + pipeline remote komutlari.
# Onceden: sudo bash tests/remote-sim-setup.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
KEYDIR="$REPO/tests/.sim-keys"
SC="$REPO/templates/scripts"
RC=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; RC=1; }

[ -f "$KEYDIR/deploy_key" ] || { echo "Once: sudo bash tests/remote-sim-setup.sh"; exit 1; }

HOST="$(cat "$KEYDIR/host" 2>/dev/null || hostname -I | awk '{print $1}')"
[ -n "$HOST" ] || HOST="127.0.0.1"
echo "$HOST" > "$KEYDIR/host"

SIM_USER="cicddeploy"
export DEPLOY_TARGET=remote
export SSH_HOST="$HOST"
export SSH_USER="$SIM_USER"
export SSH_PORT=22
export SSH_PRIVATE_KEY="$(cat "$KEYDIR/deploy_key")"
export SSH_KNOWN_HOSTS="$(cat "$KEYDIR/known_hosts")"
export CONFIG=Release

WORK="$(mktemp -d)"
DD="/opt/cicd-sim-web"
SVC="simweb"
SERVICES="web|${WORK}/fake.csproj|${DD}|${SVC}|http://${HOST}:5099/health"
export SERVICES

# --- mock nginx/systemctl/curl uzak tarafta (sudo script ile) ---
# setup-host gercek nginx kurar; simulasyonda mock PATH ile health/switch test ederiz.
# Once gercek setup-remote-host calistir (systemd birimleri olusturur).

echo "=== REMOTE SIM: setup-remote-host ==="
bash "$SC/setup-remote-host.sh"

# --- sahte artifact (minimal DLL + health mock icin basit dosya) ---
ART="$(mktemp -d)"
mkdir -p "$ART/web"
# systemd ExecStart: dotnet ${unit_dir}/fake.dll — sahte DLL yeterli degil ama
# restart sonrasi health mock ile test edecegiz; once dosyalari rsync et.
echo "sim artifact" > "$ART/web/fake.dll"
echo "KEY=VAL" > /tmp/sim-env.txt

# Mock curl uzak tarafta: remote_sudo_stdin health check icin
# Health asamasinda gercek curl kullanilir; sim icin uzakta fake curl wrapper kuralim.
REMOTE_MOCK_SETUP='
if command -v curl >/dev/null 2>&1 && [ ! -f /usr/local/bin/curl.real ]; then
  cp "$(command -v curl)" /usr/local/bin/curl.real
fi
cat > /usr/local/bin/curl <<'"'"'CURL'"'"'
#!/bin/bash
echo 200
CURL
chmod +x /usr/local/bin/curl
'

SCRIPT_DIR="$SC" source "$SC/ssh-remote.sh"
ssh_remote_init
remote_sudo "$REMOTE_MOCK_SETUP"

echo "=== REMOTE SIM: deploy-artifacts ==="
export ARTIFACT_ROOT="$ART"
bash "$SC/pipeline.sh" deploy-artifacts && pass "R1 deploy-artifacts" || fail "R1 deploy-artifacts"

echo "=== REMOTE SIM: write-env ==="
export APP_ENV="SIM_TEST=1"
bash "$SC/pipeline.sh" write-env && pass "R2 write-env" || fail "R2 write-env"

echo "=== REMOTE SIM: write-info ==="
export GIT_SHA="sim123" DEPLOYED_BY="test" DEPLOY_NOTE="remote-sim"
bash "$SC/pipeline.sh" write-info && pass "R3 write-info" || fail "R3 write-info"

echo "=== REMOTE SIM: color_active (remote read) ==="
ACTIVE="$(remote_ssh "cat /etc/nginx/cicd/${SVC}.active" 2>/dev/null || echo blue)"
[ "$ACTIVE" = "blue" ] && pass "R4 initial active=blue" || fail "R4 active=$ACTIVE"

echo "=== REMOTE SIM: health (mock curl -> 200) ==="
bash "$SC/pipeline.sh" health && pass "R5 health" || fail "R5 health"

echo "=== REMOTE SIM: switch (nginx reload gercek) ==="
bash "$SC/pipeline.sh" switch && pass "R6 switch" || fail "R6 switch"

NEW_ACTIVE="$(remote_ssh "cat /etc/nginx/cicd/${SVC}.active")"
[ "$NEW_ACTIVE" = "green" ] && pass "R7 active=green after switch" || fail "R7 active=$NEW_ACTIVE"

UP="$(remote_ssh "grep -o 'simweb-[a-z]*' /etc/nginx/cicd/${SVC}-upstream.conf | head -1")"
echo "$UP" | grep -q 'simweb-green' && pass "R8 upstream=green" || fail "R8 upstream=$UP"

echo "=== REMOTE SIM: rollback (onceki surum blue dizininde) ==="
remote_sudo "mkdir -p /opt/cicd-sim-web-blue && echo 'previous-version' > /opt/cicd-sim-web-blue/fake.dll"
bash "$SC/pipeline.sh" rollback && pass "R9 rollback" || fail "R9 rollback"
RB_ACTIVE="$(remote_ssh "cat /etc/nginx/cicd/${SVC}.active")"
[ "$RB_ACTIVE" = "blue" ] && pass "R10 rollback active=blue" || fail "R10 active=$RB_ACTIVE"

echo "=== REMOTE SIM: SSH_KNOWN_HOSTS zorunluluk ==="
unset SSH_KNOWN_HOSTS
if DEPLOY_TARGET=remote SSH_HOST="$HOST" SSH_USER="$SIM_USER" SSH_PRIVATE_KEY="$(cat "$KEYDIR/deploy_key")" \
   bash -c 'source "'"$SC"'/ssh-remote.sh"; ssh_remote_init' 2>/dev/null; then
  fail "R11 SSH_KNOWN_HOSTS bosken reddedilmeli"
else
  pass "R11 SSH_KNOWN_HOSTS bos -> reddedildi"
fi

echo "============================================="
[ "$RC" -eq 0 ] && echo "REMOTE SIM: TUM TESTLER GECTI" || echo "REMOTE SIM: BASARISIZ"
rm -rf "$WORK" "$ART"
exit "$RC"
