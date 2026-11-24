#!/bin/sh
set -eu
CDPATH='' cd "$(/usr/bin/dirname "$0")/.."

for route in /healthz / /api/v1/documents/secure/1 /ruta-inexistente; do
  echo "=== $route ==="
  headers=$(/usr/bin/curl -sS -o /dev/null -D - --cacert certs/ca.crt "https://localhost:8444$route")
  printf '%s\n' "$headers" | /usr/bin/grep -iE '^(HTTP/|server:|x-powered-by:|x-content-type-options:)'
done
