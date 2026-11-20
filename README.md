# Lab1 - Seguridad defensiva

En este laboratorio uso una API sencilla con .NET 10 para practicar cómo ejecutar un servicio de forma segura con Docker.

## Cómo probarlo

```sh
docker compose up --build --wait
curl http://127.0.0.1:8081/healthz
```

Si todo funciona, la API responde `Healthy`. Para detenerla, usa `docker compose down`.

El contenedor corre con un usuario sin privilegios y un sistema de archivos de solo lectura.
