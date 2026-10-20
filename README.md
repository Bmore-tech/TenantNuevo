# CitiDirect WebDAV Relay

Reemplazo endurecido de `kevosmar/apache-citidirect`. Recibe por WebDAV los archivos que envía
CitiDirect y los reenvía por `PUT` a la API .NET (`/BANCO/`).

```
CitiDirect --PUT + Basic--> https://<relay>/<archivo>  (o /banco/<archivo>)  -->  /home/citidirect/inbox
forwarder.sh --PUT + Basic-->  TARGET_ENDPOINT/<archivo> (API .NET)  --> SQL + Blob
```

## Estructura

| Archivo | Uso |
|---|---|
| `Dockerfile` | Imagen basada en `httpd:2.4` oficial |
| `conf/httpd.conf` | Apache mínimo: `/health` y WebDAV en la raíz y en `/banco/` |
| `scripts/entrypoint.sh` | Valida variables, genera `.htpasswd` (bcrypt) y arranca servicios |
| `scripts/forwarder.sh` | Reenvía archivos estables a la API, con reintentos |
| `ssh/sshd_config` | SSH para la consola de App Service (puerto 2222, solo Kudu) |
| `.github/workflows/build-relay.yml` | Build → ACR → Web App |

## App Settings requeridos (Web App)

Usar **referencias a Key Vault** para las contraseñas:
`@Microsoft.KeyVault(SecretUri=https://<kv>.vault.azure.net/secrets/<nombre>/)`

| Variable | Obligatoria | Descripción |
|---|---|---|
| `WEBDAV_USER` | Sí | Usuario que usa CitiDirect para autenticarse en el relay |
| `WEBDAV_PASSWORD` | Sí | Contraseña de CitiDirect (**RECOMENDADO nueva, no la expuesta en el log de la aplicacion**) |
| `TARGET_ENDPOINT` | Sí | URL de la API, p. ej. `https://<app-api>.azurewebsites.net/BANCO/` (solo `https://`) |
| `TARGET_USER` | Sí | Usuario Basic que acepta la API (`DefaultUser__Username`) |
| `TARGET_PASSWORD` | Sí | Contraseña Basic de la API (`DefaultUser__Password`) |
| `WEBSITES_ENABLE_APP_SERVICE_STORAGE` | Sí | `true` → `/home` persistente (la bandeja sobrevive reinicios) |
| `WEBSITES_PORT` | Recomendado | `80` |
| `POLL_INTERVAL` | No | Segundos entre revisiones (default `5`) |
| `STABLE_SECONDS` | No | Segundos sin cambios para considerar el archivo completo (default `5`) |
| `MAX_RETRIES` | No | Intentos antes de mover a `failed/` (default `20`) |
| `KEEP_SENT` / `KEEP_SENT_DAYS` | No | Conservar copia enviada en `sent/` y por cuántos días (default `true` / `30`) |
| `MAX_UPLOAD_BYTES` | No | Tamaño máximo por archivo (default 100 MB) |
| `ENABLE_SSH` | No | `true`/`false` (default `true`) |

## Configuración del Web App

- **Instancias: 1** (sin scale-out). La bandeja en `/home` es compartida entre instancias y el
  forwarder no coordina entre ellas; con 2+ instancias un archivo podría enviarse dos veces.
- **Health check**: ruta `/health`.
- **Access restrictions**: permitir solo las IPs de salida de CitiDirect.
- **HTTPS Only**: activado. App Service termina el TLS; el contenedor escucha en el puerto 80.
- **Identidad administrada con AcrPull** sobre el ACR para descargar la imagen.

## Carpetas en `/home/citidirect`

| Carpeta | Contenido |
|---|---|
| `inbox/` | Archivos recibidos de CitiDirect, pendientes de envío |
| `sent/` | Copias enviadas con éxito (prefijo con fecha UTC) |
| `failed/` | Archivos que agotaron los reintentos; revisar y regresar a `inbox/` para reenviar |
| `retries/` | Contadores de reintentos |

## Prueba local

```bash
docker build -t citidirect-relay .
docker run --rm -p 8080:80 \
  -e WEBDAV_USER=citi -e WEBDAV_PASSWORD='Pru3ba!' \
  -e TARGET_ENDPOINT=https://<api>/BANCO/ \
  -e TARGET_USER=<usuario-api> -e TARGET_PASSWORD='<password-api>' \
  citidirect-relay

curl -i -X OPTIONS  -u citi http://localhost:8080/banco/              # DAV: 1,2
curl -i -X PROPFIND -u citi -H "Depth: 1" http://localhost:8080/banco/  # 207
curl -i -T archivo.txt -u citi http://localhost:8080/ARCHIVO202610191507  # 201 (como Citi)
```

Los logs (`[forwarder] OK/RETRY/FAIL`) aparecen en la salida del contenedor y en el Log Stream
de App Service.
