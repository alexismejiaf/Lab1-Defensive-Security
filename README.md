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
