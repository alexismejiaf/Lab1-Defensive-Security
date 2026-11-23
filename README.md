# Lab1 - Seguridad defensiva

En este laboratorio se limita el número de solicitudes a una API de .NET 10. El contenedor de Docker se ejecuta con un usuario sin privilegios y un sistema de archivos de solo lectura.

### Certificados HTTPS

Keycloak y la API usan HTTPS con una CA local. Los certificados se generan con:

```sh
./scripts/gen-certs.sh
```

## Inicio de la API

Con Docker en ejecución, se inicia la API desde la carpeta `Lab1-Defensive-Security` y se consulta `/healthz` con `curl`.

```sh
docker compose up --build --wait
curl --cacert certs/ca.crt https://localhost:8444/healthz
```

Se mostrará `Healthy` cuando el servicio esté disponible.

## Prueba manual del límite

Por defecto, `GET /` admite 5 solicitudes por IP en cada ventana fija de 10 segundos. Las solicitudes que superan el límite reciben `429`. `/healthz` sigue disponible durante la prueba.

Se envían 10 solicitudes seguidas y se muestra el código HTTP de cada respuesta. Antes de iniciar otra prueba, se esperan 10 segundos desde la última solicitud a `/`.

```sh
for intento in 1 2 3 4 5 6 7 8 9 10; do
  curl -sS --cacert certs/ca.crt -o /dev/null -w '%{http_code}\n' https://localhost:8444/
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

Keycloak emite los tokens y la API solo los valida (firma, emisor, audiencia, expiración, scope y propietario del documento). No emite tokens ni ejecuta flujos OAuth.

El archivo `.env` contiene las contraseñas del laboratorio. Se crea a partir de la plantilla y se cambian los valores:

```sh
cp .env.example .env
```

### Pruebas automatizadas

Con el entormo en ejecución:

```sh
./scripts/smoke-test.sh
```

El script obtiene los tokens con el flujo completo (formulario de login, `code` y canje con `code_verifier`) y ejecuta 22 comprobaciones. Todas deben mostrar `PASS`:

| Grupo | Comprobaciones |
|---|---|
| API | Alice accede a su documento (`200`); Alice intenta acceder al de Bob (`404`); Bob accede al suyo (`200`); acceso sin token (`401`) |
| Flujo OAuth | El flujo por contraseña está desactivado (`400`); un `code_verifier` incorrecto es rechazado (`400`); una solicitud sin PKCE es rechazada; `code_challenge_method=plain` es rechazado |
| Validación de tokens | `client_credentials` desactivado; `redirect_uri` no registrado rechazado (2 casos); firma alterada (`401`); token `alg: none`, HS256 y RS256 con otra clave (`401`, 3 casos); documento inexistente e id no numérico (`404`, 2 casos); esquema `Basic` (`401`); token válido sin `documents.read` (`403`) |
| HTTPS | Sin la CA local, el certificado de Keycloak no es de confianza; Keycloak no responde por HTTP; la API no responde por HTTP |

Con `--slow`, el script añade la prueba del token vencido (2 comprobaciones más, 24 en total). Espera a que el token cumpla 5,5 minutos desde su emisión (300 s de vida más 30 s de desfase que tolera la API). Sin esa opción, imprime `SKIP` en su lugar.

```sh
./scripts/smoke-test.sh --slow
```

### Validación de emisor y audiencia

```sh
./scripts/test-token-validation.sh
```

Deben aparecer 5 líneas `PASS`: el control con la API correcta (`200`) y, para el emisor distinto y la audiencia distinta, un `401` cuya cabecera `WWW-Authenticate` nombra la causa.
