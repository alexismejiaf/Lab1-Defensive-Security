#!/usr/bin/env bash
# Genera una CA local y certificados de servidor para Keycloak y la API (solo laboratorio).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=certs
if [ -f "$OUT/ca.crt" ] && [ "${1:-}" != "--force" ]; then
  echo "Ya existen certificados en $OUT/. Usa --force para regenerarlos."
  exit 0
fi

rm -rf "$OUT"; mkdir -p "$OUT"; cd "$OUT"

# 1) CA local
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out ca.key
openssl req -new -key ca.key -subj "/CN=Lab Local CA" -out ca.csr
openssl x509 -req -in ca.csr -signkey ca.key -sha256 -days 730 \
  -extfile <(printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n') \
  -out ca.crt

# 2) Certificados de servidor firmados por la CA. Argumentos: nombre, SAN
issue_cert() {
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$1.key"
  openssl req -new -key "$1.key" -subj "/CN=$1" -out "$1.csr"
  openssl x509 -req -in "$1.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -sha256 -days 365 \
    -extfile <(printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' "$2") \
    -out "$1.crt"
}
issue_cert keycloak "DNS:localhost,DNS:keycloak,IP:127.0.0.1"
issue_cert api      "DNS:localhost,DNS:defensive-api,IP:127.0.0.1"

rm -f ./*.csr ca.srl
chmod 600 ca.key
chmod 644 ca.crt keycloak.crt keycloak.key api.crt api.key   # los contenedores usan otros UID

echo "Certificados generados en $OUT/"