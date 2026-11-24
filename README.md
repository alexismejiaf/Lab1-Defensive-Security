# Lab1 - Seguridad defensiva

En este laboratorio se protegen los endpoints de una API de .NET 10 con hardening de cabeceras, límites de solicitudes y autenticación OAuth 2.0 con Keycloak. El contenedor de la API se ejecuta con un usuario sin privilegios y un sistema de archivos de solo lectura.

## Preparación del entorno

### macOS

Abre Docker Desktop o inicia el motor de Docker que ya uses. Los comandos se ejecutan en Terminal. Si te falta `jq` y usas Homebrew, instálalo con `brew install jq`. [Instalación de jq](https://jqlang.org/download/#macos)

### Windows

Usa Ubuntu en WSL 2 para ejecutar los scripts con Bash. Si todavía no tienes Ubuntu en WSL, ejecuta este comando en PowerShell como administrador y reinicia si Windows lo solicita. [Instalación de WSL](https://learn.microsoft.com/es-es/windows/wsl/install)

```powershell
wsl --install -d Ubuntu
```

En PowerShell, comprueba con `wsl -l -v` que Ubuntu figura con la versión 2. Si figura con la versión 1, ejecuta `wsl --set-version Ubuntu 2`.

Abre Docker Desktop. En **Settings > General**, usa el motor de WSL 2. En **Settings > Resources > WSL Integration**, habilita Ubuntu. Abre la terminal de Ubuntu e instala las herramientas del laboratorio. [Integración de Docker Desktop con WSL 2](https://docs.docker.com/desktop/features/wsl/#enable-docker-in-a-wsl-2-distribution)

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git jq openssl
```

Ejecuta el resto de los comandos desde Ubuntu. Guarda el repositorio en la carpeta personal de Ubuntu para que Docker pueda montar los archivos del laboratorio con la integración de WSL. [Archivos y montajes en WSL 2](https://docs.docker.com/desktop/features/wsl/best-practices/#optimise-file-system-performance-with-bind-mounts)

### Comandos comunes

Desde Terminal en macOS o Ubuntu en Windows, comprueba que Docker esté activo y que las herramientas estén disponibles.

```bash
docker version
docker compose version
command -v git bash curl jq openssl
```

Si ya tienes el repositorio, abre su carpeta y continúa con **Inicio de la API**. Para descargarlo por primera vez, ejecuta estos comandos desde la carpeta donde quieras guardarlo.

```bash
git clone https://github.com/alexismejiaf/Lab1-Defensive-Security.git
cd Lab1-Defensive-Security
```

## Inicio de la API

Desde la raíz del repositorio, crea `.env` con las tres contraseñas de laboratorio definidas en [`.env.example`](.env.example). Este bloque genera valores aleatorios si el archivo aún no existe.

```bash
if [ ! -e .env ]; then
  (
    umask 077
    for key in KC_ADMIN_PASSWORD ALICE_PASSWORD BOB_PASSWORD; do
      printf '%s=%s\n' "$key" "$(openssl rand -hex 24)"
    done > .env
  )
fi
```

### Certificados HTTPS

Genera la CA local y los certificados de Keycloak y de la API.

```bash
./scripts/gen-certs.sh
```

### Arranque con Docker

Deja libres los puertos locales `8443` y `8444` para Keycloak y la API, y `8445` y `8446` para las pruebas de emisor y audiencia. Las comprobaciones de OAuth también esperan que `8080` y `8081` estén libres en el equipo anfitrión.

Compose usa 10 solicitudes por 60 segundos por omisión. Para reproducir los resultados de esta guía, inicia el laboratorio con 5 solicitudes por 10 segundos.

```bash
RateLimit__PermitLimit=5 RateLimit__WindowSeconds=10 \
  docker compose up --build --wait --wait-timeout 120 -d
docker compose ps
curl -fsS -D - --cacert certs/ca.crt https://localhost:8444/healthz
```

La última llamada debe devolver `200` y `Healthy`. Las pruebas usan la CA local para validar los certificados.

### Comprobación de cabeceras

Con la API en ejecución, usa el script desde la raíz del repositorio.

```bash
./scripts/test-headers.sh
```

También puedes ejecutar la comprobación directamente en la terminal.

```bash
for route in /healthz / /api/v1/documents/secure/1 /ruta-inexistente; do
  echo "=== $route ==="
  /usr/bin/curl -sS -o /dev/null -D - --cacert certs/ca.crt "https://localhost:8444$route" | /usr/bin/grep -iE '^(HTTP/|server:|x-powered-by:|x-content-type-options:)'
done
```

Se esperan `200` para `/healthz` y `/` si hay cuota disponible, `401` para el documento sin token y `404` para la ruta inexistente. Cada respuesta debe incluir `X-Content-Type-Options: nosniff` y omitir `Server` y `X-Powered-By`.

## Prueba manual del límite

Envía diez solicitudes seguidas a `GET /`. Con la configuración del arranque, las primeras cinco deben devolver `200` y las siguientes cinco, `429`.

```bash
for request in 1 2 3 4 5 6 7 8 9 10; do
  curl -sS --cacert certs/ca.crt -o /dev/null -w '%{http_code}\n' https://localhost:8444/
done
```

## Prueba automatizada

Deja pasar una ventana completa después de la prueba manual. El script comprueba los diez códigos de respuesta y devuelve un error si alguno difiere de lo esperado.

```bash
sleep 11
RateLimit__PermitLimit=5 sh scripts/test-rate-limit.sh 10
```

## Cambio del límite

Para comprobar otro valor, vuelve a iniciar la API con un límite de 8 solicitudes por IP y mantén la ventana de 10 segundos. Deben aparecer ocho códigos `200` y dos `429`.

```bash
RateLimit__PermitLimit=8 RateLimit__WindowSeconds=10 \
  docker compose up --wait --wait-timeout 120 -d defensive-api
RateLimit__PermitLimit=8 sh scripts/test-rate-limit.sh 10
```

## Autenticación (OAuth 2.0 + JWT Bearer con Keycloak)

Keycloak emite los tokens mediante Authorization Code con PKCE (`S256`). La API valida la firma, el emisor, la audiencia y la expiración del JWT. También comprueba el permiso `documents.read` y que el documento pertenezca al usuario.

### Pruebas automatizadas

Con Docker en ejecución, ejecuta la prueba completa desde la raíz del repositorio.

```bash
./scripts/smoke-test.sh --slow
```

Se esperan 24 líneas `PASS`. La prueba de expiración tarda unos 5 minutos y medio. Para una comprobación rápida, ejecuta `./scripts/smoke-test.sh` y espera 22 resultados `PASS` y un `SKIP` para la expiración.

| Grupo | Comprobaciones |
|---|---|
| Acceso a documentos | Acceso al documento propio (`200`), documento ajeno o inexistente (`404`), solicitud sin token (`401`) y token válido sin `documents.read` (`403`). |
| Flujo OAuth | Rechazo del flujo por contraseña, de `client_credentials`, de un verificador incorrecto, de solicitudes sin PKCE o con `plain`, y de redirecciones no registradas. |
| Validación del JWT | Rechazo de firmas inválidas, tokens sin firma, tokens vencidos y solicitudes con el esquema `Basic`. |
| HTTPS | Validación de la CA local y comprobación de los puertos HTTP desde el equipo anfitrión. |

### Validación de emisor y audiencia

Cuando termine la prueba anterior, ejecuta el segundo script con los servicios todavía activos. El script utiliza dos contenedores temporales para comprobar el emisor y la audiencia por separado.

```bash
./scripts/test-token-validation.sh
```

Se esperan cinco líneas `PASS`. El mismo token debe recibir `200` en la API con la configuración correcta y `401` en las variantes con otro emisor u otra audiencia. La cabecera `WWW-Authenticate` indica la causa de cada rechazo.

## Detención del servicio

Cuando terminen ambas pruebas de OAuth y las del límite, detén el entorno.

```bash
docker compose down
```
