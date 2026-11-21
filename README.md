# Lab1 - Seguridad defensiva

En este laboratorio uso una API sencilla con .NET 10 para practicar cómo ejecutar un servicio de forma segura con Docker.

## Cómo probarlo

```sh
docker compose up --build --wait
curl http://127.0.0.1:8081/healthz
```

Si todo funciona, la API responde `Healthy`. Para detenerla, usa `docker compose down`.

El contenedor corre con un usuario sin privilegios y un sistema de archivos de solo lectura.

## Autenticación (OAuth 2.0 + JWT Bearer con Keycloak)

```sh
cp .env.example .env   # y cambia los valores por secretos propios
docker compose up --build --wait -d
./scripts/smoke-test.sh
```

Keycloak importa el realm `lab` desde `keycloak/lab-realm.json` al arrancar
(cliente `documents-client`, usuarios `alice` y `bob`, scope `documents.read`).
La API solo valida los tokens; no los emite.

Ejemplo de token y llamada:

```sh
set -a; source .env; set +a
TOKEN=$(curl -s -X POST http://localhost:8080/realms/lab/protocol/openid-connect/token \
  -d grant_type=password -d client_id=documents-client \
  --data-urlencode client_secret="$DOCUMENTS_CLIENT_SECRET" \
  -d username=alice --data-urlencode password="$ALICE_PASSWORD" \
  -d scope=documents.read | jq -r .access_token)
curl -i -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8081/api/v1/documents/secure/1
```

> Solo para laboratorio: Keycloak en modo `start-dev`, HTTP sin TLS y
> `grant_type=password` (un cliente real usaría authorization code + PKCE).
