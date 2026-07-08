#!/usr/bin/env bash
#
# CI/CD Blueprint - servis saglik kontrolu / service health check
#
# Verilen taban adres icin sirasiyla dener / tries in order for a base URL:
#   1) <base>/health -> {"status":"ok"} icerir mi / contains it
#   2) <base>/health -> HTTP 200
#   3) <base>/        -> HTTP 200
# Herhangi biri olumluysa servis saglikli sayilir.
# Service is considered healthy if any of these succeeds.
#
# Unix socket modu (5. arg verilince) / Unix socket mode (when 5th arg is given):
#   curl --unix-socket kullanir; sadece HTTP 200 kontrol eder.
#   Uses curl --unix-socket; checks HTTP 200 only.
#
# Kullanim / Usage:
#   bash verify-health.sh <base_url> [health_path] [max_attempts] [sleep_seconds] [unix_socket]
#
#   Ornek - public URL / Example - public URL:
#     bash verify-health.sh http://10.0.0.5:5000 /health 12 5
#
#   Ornek - Unix socket (lokal test) / Example - Unix socket (local test):
#     bash verify-health.sh http://localhost /health 12 5 /run/cicd/myapp-blue.sock

set -euo pipefail

BASE_URL="${1:?taban adres gerekli / base url required}"
HEALTH_PATH="${2:-/health}"
MAX_ATTEMPTS="${3:-12}"
SLEEP_SECONDS="${4:-5}"
UNIX_SOCKET="${5:-}"

BASE_URL="${BASE_URL%/}"
HEALTH_PATH="/${HEALTH_PATH#/}"

check_service_up() {
  local body status

  if [ -n "$UNIX_SOCKET" ]; then
    # Unix socket modu: curl --unix-socket ile direkt socket kontrol
    # Unix socket mode: direct socket check via curl --unix-socket
    status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
      --unix-socket "$UNIX_SOCKET" "http://localhost${HEALTH_PATH}" 2>/dev/null || echo 000)"
    if [ "$status" = "200" ]; then
      echo "kontrol / check: unix-socket ${HEALTH_PATH} 200"
      return 0
    fi
    return 1
  fi

  # Public URL modu: once status=ok, sonra HTTP 200 / Public URL mode: status=ok then HTTP 200
  body="$(curl -fsS --max-time 10 "${BASE_URL}${HEALTH_PATH}" 2>/dev/null || true)"
  if printf '%s' "$body" | grep -qE '"status"[[:space:]]*:[[:space:]]*"ok"'; then
    echo "kontrol / check: ${HEALTH_PATH} status=ok"
    return 0
  fi

  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${BASE_URL}${HEALTH_PATH}" 2>/dev/null || echo 000)"
  if [ "$status" = "200" ]; then
    echo "kontrol / check: ${HEALTH_PATH} 200"
    return 0
  fi

  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${BASE_URL}/" 2>/dev/null || echo 000)"
  if [ "$status" = "200" ]; then
    echo "kontrol / check: / 200"
    return 0
  fi

  return 1
}

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  if check_service_up; then
    echo "saglikli / healthy (${attempt}/${MAX_ATTEMPTS}): ${UNIX_SOCKET:-${BASE_URL}}"
    exit 0
  fi
  echo "bekleniyor / waiting (${attempt}/${MAX_ATTEMPTS}), ${SLEEP_SECONDS}s..."
  sleep "$SLEEP_SECONDS"
done

echo "saglik kontrolu basarisiz / health check failed: ${UNIX_SOCKET:-${BASE_URL}}"
exit 1
