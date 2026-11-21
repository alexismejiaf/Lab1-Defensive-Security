# Lab1 - Seguridad defensiva

En este laboratorio se limita el número de solicitudes a una API de .NET 10. El contenedor de Docker se ejecuta con un usuario sin privilegios y un sistema de archivos de solo lectura.

## Inicio de la API

Con Docker en ejecución, se inicia la API desde la carpeta `Lab1-Defensive-Security` y se consulta `/healthz` con `curl`.

```sh
docker compose up --build --wait
curl http://127.0.0.1:8081/healthz
```

Se mostrará `Healthy` cuando el servicio esté disponible.

## Prueba manual del límite

Por defecto, `GET /` admite 5 solicitudes por IP en cada ventana fija de 10 segundos. Las solicitudes que superan el límite reciben `429`. `/healthz` sigue disponible durante la prueba.

Se envían 10 solicitudes seguidas y se muestra el código HTTP de cada respuesta. Antes de iniciar otra prueba, se esperan 10 segundos desde la última solicitud a `/`.

```sh
for intento in 1 2 3 4 5 6 7 8 9 10; do
  curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/
done
```

Se mostrarán cinco códigos `200` (solicitud aceptada), seguidos de cinco códigos `429` (límite superado).

## Prueba automatizada

Se define en `intentos` el total de solicitudes. El script completa todos los intentos, incluso después de un `429`. Con el límite predeterminado, se esperan códigos `200` en los primeros cinco intentos y `429` a partir del sexto. Si algún intento falla o devuelve un código inesperado, el script devuelve un error al finalizar.

```sh
intentos=10
sh scripts/test-rate-limit.sh "$intentos"
```

## Cambio del límite

Para verificar que la API aplica otro valor, se incrementa el límite de 5 a 8 solicitudes por IP con `RateLimit__PermitLimit`. Se mantiene la ventana de 10 segundos con `RateLimit__WindowSeconds`.

```sh
intentos=10
limite=8
RateLimit__PermitLimit="$limite" RateLimit__WindowSeconds=10 docker compose up --build --wait
RateLimit__PermitLimit="$limite" sh scripts/test-rate-limit.sh "$intentos"
```

Se mostrarán ocho códigos `200` seguidos de dos códigos `429`.

## Detención del servicio

Al finalizar, se detiene el contenedor.

```sh
docker compose down
```

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
