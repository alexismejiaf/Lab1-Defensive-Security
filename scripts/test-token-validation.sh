#!/usr/bin/env bash
# Comprueba que la API rechaza un token genuino de Keycloak cuando espera otro emisor
# u otra audiencia. Para cada caso levanta una copia temporal de la API (en otro puerto)
# con la configuración alterada y le envía el mismo token válido.
# Requisito: el entorno debe estar en ejecución (docker compose up --build --wait).
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; source .env; set +a

CA=certs/ca.crt
[ -f "$CA" ] || { echo "Falta $CA. Ejecuta ./scripts/gen-certs.sh primero." >&2; exit 1; }
command -v docker >/dev/null || { echo "Se necesita docker." >&2; exit 1; }

KC=https://localhost:8443
API=https://localhost:8444
OIDC="$KC/realms/lab/protocol/openid-connect"
CLIENT_ID=documents-client
REDIRECT_URI=http://localhost:3000/callback
ISSUER_PORT=8445
AUDIENCE_PORT=8446
TMP_ISSUER=lab-api-wrong-issuer
TMP_AUDIENCE=lab-api-wrong-audience
FAILED=0

# Todas las llamadas validan el certificado del servidor contra la CA local
curl() { command curl --cacert "$CA" "$@"; }

JAR=$(mktemp)
cleanup() { rm -f "$JAR"; docker rm -f "$TMP_ISSUER" "$TMP_AUDIENCE" >/dev/null 2>&1 || true; }
trap cleanup EXIT
trap 'exit 1' INT TERM

echo "Esperando a Keycloak..."
until curl -sf "$KC/realms/lab/.well-known/openid-configuration" >/dev/null; do sleep 2; done
echo "Esperando a la API..."
until curl -sf "$API/healthz" >/dev/null; do sleep 2; done

# --- Authorization Code + PKCE (S256), igual que en smoke-test.sh ---------
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
new_verifier() { openssl rand -hex 32; }
challenge_of() { printf %s "$1" | openssl dgst -sha256 -binary | b64url; }

get_code() {  # usuario, contraseña, code_challenge
  local page action headers code
  : > "$JAR"
  page=$(curl -s -c "$JAR" -b "$JAR" -G "$OIDC/auth" \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode "redirect_uri=$REDIRECT_URI" \
    --data-urlencode "response_type=code" \
    --data-urlencode "scope=documents.read" \
    --data-urlencode "state=$(openssl rand -hex 8)" \
    --data-urlencode "code_challenge=$3" \
    --data-urlencode "code_challenge_method=S256")
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

get_token() {  # usuario, contraseña
  local verifier code resp tok
  verifier=$(new_verifier)
  code=$(get_code "$1" "$2" "$(challenge_of "$verifier")")
  resp=$(curl -s -X POST "$OIDC/token" \
    -d grant_type=authorization_code -d "client_id=$CLIENT_ID" \
    --data-urlencode "redirect_uri=$REDIRECT_URI" \
    --data-urlencode "code=$code" --data-urlencode "code_verifier=$verifier")
  tok=$(echo "$resp" | jq -r '.access_token // empty')
  if [ -z "$tok" ]; then echo "El intercambio del code falló para $1: $resp" >&2; return 1; fi
  echo "$tok"
}

# --- Utilidades de prueba --------------------------------------------------
check() {
  if [ "$2" = "$3" ]; then echo "PASS  $1 ($3)"; else echo "FAIL  $1 (esperado $2, obtenido $3)"; FAILED=1; fi
}

# Pasa si la cabecera WWW-Authenticate (en minúsculas) contiene la palabra indicada
check_reason() {
  case "$3" in
    *"$2"*) echo "PASS  $1" ;;
    *) echo "FAIL  $1 (cabecera: ${3:-vacía})"; FAILED=1 ;;
  esac
}

# Levanta una copia temporal de la API. Argumentos: nombre, puerto, VARIABLE=valor
start_api() {
  docker rm -f "$1" >/dev/null 2>&1 || true
  docker compose run -d --no-deps --name "$1" -p "127.0.0.1:$2:8443" -e "$3" defensive-api >/dev/null
  local tries=60
  until curl -sf "https://localhost:$2/healthz" >/dev/null; do
    tries=$((tries - 1))
    if [ "$tries" -le 0 ]; then
      echo "La API temporal $1 no arrancó." >&2; docker logs --tail 20 "$1" >&2 || true; return 1
    fi
    sleep 1
  done
}

# Envía el token a una URL e imprime "<estado>|<cabecera www-authenticate en minúsculas>"
probe() {
  local out header
  out=$(curl -s -o /dev/null -D - -w '\nSTATUS=%{http_code}' -H "Authorization: Bearer $TOKEN" "$1")
  header=$(printf '%s' "$out" | tr -d '\r' | grep -i '^www-authenticate:' | tr '[:upper:]' '[:lower:]' || true)
  printf '%s|%s' "${out##*STATUS=}" "$header"
}

# --- Pruebas ---------------------------------------------------------------
TOKEN=$(get_token alice "$ALICE_PASSWORD")
PATH_DOC=/api/v1/documents/secure/1

# Control: el mismo token es válido en la API configurada correctamente
R=$(probe "$API$PATH_DOC")
check "Control: el token es válido en la API con la configuración correcta" 200 "${R%%|*}"

# Emisor distinto
echo "Levantando una API que espera otro emisor..."
start_api "$TMP_ISSUER" "$ISSUER_PORT" "Authentication__Issuer=https://otro-emisor.example/realms/lab"
R=$(probe "https://localhost:$ISSUER_PORT$PATH_DOC")
check "Un token de otro emisor es rechazado" 401 "${R%%|*}"
check_reason "El rechazo indica que el emisor no es válido" issuer "${R#*|}"

# Audiencia distinta
echo "Levantando una API que espera otra audiencia..."
start_api "$TMP_AUDIENCE" "$AUDIENCE_PORT" "Authentication__Audience=otra-api"
R=$(probe "https://localhost:$AUDIENCE_PORT$PATH_DOC")
check "Un token con otra audiencia es rechazado" 401 "${R%%|*}"
check_reason "El rechazo indica que la audiencia no es válida" audience "${R#*|}"

exit $FAILED