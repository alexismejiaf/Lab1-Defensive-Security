#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; source .env; set +a

KC=http://localhost:8080
API=http://127.0.0.1:8081
FAILED=0

echo "Waiting for Keycloak..."
until curl -sf "$KC/realms/lab/.well-known/openid-configuration" >/dev/null; do sleep 2; done
echo "Waiting for the API..."
until curl -sf "$API/healthz" >/dev/null; do sleep 2; done

get_token() {
  local resp tok
  resp=$(curl -s -X POST "$KC/realms/lab/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=documents-client \
    --data-urlencode client_secret="$DOCUMENTS_CLIENT_SECRET" \
    -d username="$1" --data-urlencode password="$2" -d scope=documents.read)
  tok=$(echo "$resp" | jq -r '.access_token // empty')
  if [ -z "$tok" ]; then echo "Token request failed for $1: $resp" >&2; exit 1; fi
  echo "$tok"
}

status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

check() {
  if [ "$2" = "$3" ]; then echo "PASS  $1 ($3)"; else echo "FAIL  $1 (expected $2, got $3)"; FAILED=1; fi
}

ALICE=$(get_token alice "$ALICE_PASSWORD")
BOB=$(get_token bob "$BOB_PASSWORD")
URL="$API/api/v1/documents/secure"

check "Alice accede con su token a su documento".              200 "$(status -H "Authorization: Bearer $ALICE" "$URL/1")"
check "Alice intenta acceder con su token al documento de Bob" 404 "$(status -H "Authorization: Bearer $ALICE" "$URL/2")"
check "Bob accede con su token a su documento"                 200 "$(status -H "Authorization: Bearer $BOB"   "$URL/2")"
check "Un usuario intenta acceder sin un token"                401 "$(status "$URL/1")"

exit $FAILED