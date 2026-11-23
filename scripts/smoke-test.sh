#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; source .env; set +a

# Uso: ./scripts/smoke-test.sh [--slow]
#   --slow  añade la prueba del token vencido (espera hasta ~5,5 minutos)
SLOW=0
if [ "${1:-}" = "--slow" ]; then SLOW=1; fi

CA=certs/ca.crt
[ -f "$CA" ] || { echo "Falta $CA. Ejecuta ./scripts/gen-certs.sh primero." >&2; exit 1; }
KC=https://localhost:8443
API=https://localhost:8444
OIDC="$KC/realms/lab/protocol/openid-connect"
CLIENT_ID=documents-client
REDIRECT_URI=http://localhost:3000/callback
SCOPE=documents.read   # scope que se solicita; vacío = sin parámetro scope
FAILED=0
# Todas las llamadas validan el certificado del servidor contra la CA local
curl() { command curl --cacert "$CA" "$@"; }
JAR=$(mktemp)
trap 'rm -f "$JAR"' EXIT

echo "Esperando a Keycloak..."
until curl -sf "$KC/realms/lab/.well-known/openid-configuration" >/dev/null; do sleep 2; done
echo "Esperando a la API..."
until curl -sf "$API/healthz" >/dev/null; do sleep 2; done

# --- PKCE (S256) ---------------------------------------------------------
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
new_verifier() { openssl rand -hex 32; }                       # 64 caracteres
challenge_of() { printf %s "$1" | openssl dgst -sha256 -binary | b64url; }

# Pide la página de autorización. Argumentos: code_challenge, code_challenge_method
authorize_page() {
  : > "$JAR"
  local args=(-s -c "$JAR" -b "$JAR" -G "$OIDC/auth"
    --data-urlencode "client_id=$CLIENT_ID"
    --data-urlencode "redirect_uri=$REDIRECT_URI"
    --data-urlencode "response_type=code"
    --data-urlencode "state=$(openssl rand -hex 8)")
  [ -n "$SCOPE" ] && args+=(--data-urlencode "scope=$SCOPE")
  [ -n "${1:-}" ] && args+=(--data-urlencode "code_challenge=$1")
  [ -n "${2:-}" ] && args+=(--data-urlencode "code_challenge_method=$2")
  curl "${args[@]}"
}

# Inicia sesión en el formulario de Keycloak y devuelve el authorization code.
# Argumentos: usuario, contraseña, code_challenge
get_code() {
  local page action headers code
  page=$(authorize_page "$3" S256)
  action=$(printf %s "$page" | tr '\n' ' ' \
    | grep -o '<form[^>]*kc-form-login[^>]*>' | grep -o 'action="[^"]*"' | head -1 \
    | sed 's/^action="//; s/"$//; s/&amp;/\&/g')
  if [ -z "$action" ]; then echo "No se encontró el formulario de login para $1" >&2; return 1; fi
  headers=$(curl -s -o /dev/null -D - -c "$JAR" -b "$JAR" -X POST "$action" \
    --data-urlencode "username=$1" --data-urlencode "password=$2" -d "credentialId=")
  code=$(printf %s "$headers" | tr -d '\r' | sed -n 's/^[Ll]ocation:.*[?&]code=\([^&]*\).*/\1/p' | head -1)
  if [ -z "$code" ]; then echo "Keycloak no devolvió un code para $1" >&2; return 1; fi
  echo "$code"
}

# Intercambia el code por tokens. Argumentos: code, code_verifier. Imprime la respuesta JSON.
exchange_code() {
  curl -s -X POST "$OIDC/token" \
    -d grant_type=authorization_code \
    -d "client_id=$CLIENT_ID" \
    --data-urlencode "redirect_uri=$REDIRECT_URI" \
    --data-urlencode "code=$1" \
    --data-urlencode "code_verifier=$2"
}

# Flujo completo: Authorization Code + PKCE. Argumentos: usuario, contraseña.
get_token() {
  local verifier challenge code resp tok
  verifier=$(new_verifier)
  challenge=$(challenge_of "$verifier")
  code=$(get_code "$1" "$2" "$challenge")
  resp=$(exchange_code "$code" "$verifier")
  tok=$(echo "$resp" | jq -r '.access_token // empty')
  if [ -z "$tok" ]; then echo "El intercambio del code falló para $1: $resp" >&2; return 1; fi
  echo "$tok"
}

status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

check() {
  if [ "$2" = "$3" ]; then echo "PASS  $1 ($3)"; else echo "FAIL  $1 (esperado $2, obtenido $3)"; FAILED=1; fi
}

# --- Pruebas de la API ---------------------------------------------------
ALICE=$(get_token alice "$ALICE_PASSWORD")
BOB=$(get_token bob "$BOB_PASSWORD")
# Token válido de Alice pedido sin el scope documents.read
NOSCOPE=$(SCOPE="" get_token alice "$ALICE_PASSWORD")
# Con --slow se emite ahora un token que se probará al final, cuando ya haya vencido
if [ "$SLOW" = 1 ]; then
  EXPIRING=$(get_token alice "$ALICE_PASSWORD")
  EXPIRING_AT=$(date +%s)
fi
URL="$API/api/v1/documents/secure"

check "Alice accede con su token a su documento"               200 "$(status -H "Authorization: Bearer $ALICE" "$URL/1")"
check "Alice intenta acceder con su token al documento de Bob" 404 "$(status -H "Authorization: Bearer $ALICE" "$URL/2")"
check "Bob accede con su token a su documento"                 200 "$(status -H "Authorization: Bearer $BOB"   "$URL/2")"
check "Un usuario intenta acceder sin un token"                401 "$(status "$URL/1")"

# --- Pruebas del flujo OAuth ---------------------------------------------
# 1) El flujo por contraseña ya no debe funcionar
check "El flujo por contraseña está desactivado" 400 "$(status -X POST "$OIDC/token" \
  -d grant_type=password -d "client_id=$CLIENT_ID" \
  -d username=alice --data-urlencode "password=$ALICE_PASSWORD" -d scope=documents.read)"

# 2) Un code_verifier incorrecto debe ser rechazado
V=$(new_verifier); C=$(challenge_of "$V")
CODE=$(get_code alice "$ALICE_PASSWORD" "$C")
check "Un code_verifier incorrecto es rechazado" 400 "$(status -X POST "$OIDC/token" \
  -d grant_type=authorization_code -d "client_id=$CLIENT_ID" \
  --data-urlencode "redirect_uri=$REDIRECT_URI" --data-urlencode "code=$CODE" \
  --data-urlencode "code_verifier=$(new_verifier)")"

# 3) La solicitud de autorización sin PKCE o con 'plain' no debe mostrar el login
page=$(authorize_page "" "")
if [[ "$page" == *kc-form-login* ]]; then
  echo "FAIL  Se aceptó una solicitud sin PKCE"; FAILED=1
else echo "PASS  Una solicitud sin PKCE es rechazada"; fi

page=$(authorize_page "$(new_verifier)" plain)
if [[ "$page" == *kc-form-login* ]]; then
  echo "FAIL  Se aceptó code_challenge_method=plain"; FAILED=1
else echo "PASS  code_challenge_method=plain es rechazado"; fi

# --- Pruebas adicionales de OAuth y de validación de tokens --------------
ALICE_ID=7c1d2a10-3b5e-4f6a-9d11-0a1b2c3d4e01

# Devuelve "<estado HTTP> <valor de error>" de una solicitud al endpoint de tokens
token_request() {
  local out code body err
  out=$(curl -s -w '\n%{http_code}' -X POST "$OIDC/token" "$@")
  code=$(printf '%s\n' "$out" | tail -n 1)
  body=$(printf '%s\n' "$out" | sed '$d')
  err=$(printf '%s' "$body" | jq -r '.error // "none"' 2>/dev/null) || true
  printf '%s %s' "$code" "${err:-none}"
}

# Pasa si el valor obtenido coincide con alguno de los esperados (separados por |)
check_match() {
  case "|$2|" in
    *"|$3|"*) echo "PASS  $1 ($3)" ;;
    *) echo "FAIL  $1 (esperado $2, obtenido $3)"; FAILED=1 ;;
  esac
}

# 1) El flujo client_credentials está desactivado (el cliente es público)
check_match "El flujo client_credentials está desactivado" \
  "400 unauthorized_client|401 unauthorized_client" \
  "$(token_request -d grant_type=client_credentials -d "client_id=$CLIENT_ID" -d scope=documents.read)"

# 2) Un redirect_uri no registrado se rechaza sin mostrar el login
for bad_uri in http://evil.example/callback http://localhost:3000/otra-ruta; do
  out=$(curl -s -w '\n%{http_code}' -G "$OIDC/auth" \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode "redirect_uri=$bad_uri" \
    --data-urlencode "response_type=code" \
    --data-urlencode "scope=documents.read" \
    --data-urlencode "code_challenge=$(challenge_of "$(new_verifier)")" \
    --data-urlencode "code_challenge_method=S256")
  code=$(printf '%s\n' "$out" | tail -n 1)
  if [ "$code" = 400 ] && [[ "$out" != *kc-form-login* ]]; then
    echo "PASS  redirect_uri no registrado es rechazado ($bad_uri)"
  else
    echo "FAIL  redirect_uri no registrado: se esperaba 400 sin login, se obtuvo $code ($bad_uri)"; FAILED=1
  fi
done

# 3) Un token con la firma alterada es rechazado
SIG=${ALICE##*.}
TAMPERED="${ALICE%.*}.$([ "${SIG:0:1}" = A ] && echo B || echo A)${SIG:1}"
check "Un token con la firma alterada es rechazado" 401 \
  "$(status -H "Authorization: Bearer $TAMPERED" "$URL/1")"

# 4) Tokens falsificados con los datos de Alice
NOW=$(date +%s)
CLAIMS=$(printf '{"iss":"%s/realms/lab","aud":"documents-api","sub":"%s","scope":"documents.read","iat":%s,"exp":%s}' \
  "$KC" "$ALICE_ID" "$NOW" "$((NOW + 300))")
PAYLOAD=$(printf '%s' "$CLAIMS" | b64url)
jwt_header() { printf '{"alg":"%s","typ":"JWT"}' "$1" | b64url; }

# 4a) Sin firma (alg none)
UNSIGNED="$(jwt_header none).$PAYLOAD."
# 4b) HS256 con una clave inventada
H_HS=$(jwt_header HS256)
HS_SIG=$(printf '%s' "$H_HS.$PAYLOAD" | openssl dgst -sha256 -hmac "otra-clave" -binary | b64url)
# 4c) RS256 con una clave RSA distinta de la de Keycloak
ATTACKER_KEY=$(mktemp)
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$ATTACKER_KEY" 2>/dev/null
H_RS=$(jwt_header RS256)
RS_SIG=$(printf '%s' "$H_RS.$PAYLOAD" | openssl dgst -sha256 -sign "$ATTACKER_KEY" | b64url)
rm -f "$ATTACKER_KEY"

check "Un token sin firma (alg none) es rechazado" 401 \
  "$(status -H "Authorization: Bearer $UNSIGNED" "$URL/1")"
check "Un token HS256 firmado con otra clave es rechazado" 401 \
  "$(status -H "Authorization: Bearer $H_HS.$PAYLOAD.$HS_SIG" "$URL/1")"
check "Un token RS256 firmado con otra clave es rechazado" 401 \
  "$(status -H "Authorization: Bearer $H_RS.$PAYLOAD.$RS_SIG" "$URL/1")"

# 5) Peticiones a recursos inexistentes o con otro esquema de autorización
check "Un documento inexistente devuelve 404" 404 \
  "$(status -H "Authorization: Bearer $ALICE" "$URL/99")"
check "Un id no numérico devuelve 404" 404 \
  "$(status -H "Authorization: Bearer $ALICE" "$URL/abc")"
check "El esquema Basic en lugar de Bearer es rechazado" 401 \
  "$(status -H "Authorization: Basic YWxpY2U6eA==" "$URL/1")"

# 6) Un token válido (firma, emisor, audiencia y vigencia) sin documents.read recibe 403
check "Un token válido sin documents.read recibe 403" 403 \
  "$(status -H "Authorization: Bearer $NOSCOPE" "$URL/1")"

# --- Pruebas de HTTPS ----------------------------------------------------
if command curl -s -o /dev/null --max-time 5 "$KC/realms/lab/.well-known/openid-configuration"; then
  echo "FAIL  Keycloak es de confianza sin la CA local"; FAILED=1
else echo "PASS  Sin la CA local, el certificado de Keycloak no es de confianza"; fi

if curl -s -o /dev/null --max-time 3 http://localhost:8080/; then
  echo "FAIL  Keycloak responde por HTTP"; FAILED=1
else echo "PASS  Keycloak no responde por HTTP"; fi

if curl -s -o /dev/null --max-time 3 http://127.0.0.1:8081/healthz; then
  echo "FAIL  La API responde por HTTP"; FAILED=1
else echo "PASS  La API no responde por HTTP"; fi

# --- Token vencido (solo con --slow) -------------------------------------
if [ "$SLOW" = 1 ]; then
  # Duración del token (300 s) + desfase que tolera la API (30 s) + margen
  WAIT=$((335 - ($(date +%s) - EXPIRING_AT)))
  if [ "$WAIT" -gt 0 ]; then echo "Esperando ${WAIT}s a que expire el token..."; sleep "$WAIT"; fi
  OUT=$(curl -s -o /dev/null -D - -w '\nSTATUS=%{http_code}' -H "Authorization: Bearer $EXPIRING" "$URL/1")
  check "Un token vencido es rechazado" 401 "${OUT##*STATUS=}"
  OUT_LC=$(printf '%s' "$OUT" | tr '[:upper:]' '[:lower:]')
  if [[ "$OUT_LC" == *"token expired"* ]]; then
    echo "PASS  El rechazo indica que el token expiró"
  else
    echo "FAIL  El rechazo no indica que el token expiró"; FAILED=1
  fi
else
  echo "SKIP  Token vencido (ejecuta con --slow)"
fi

exit $FAILED