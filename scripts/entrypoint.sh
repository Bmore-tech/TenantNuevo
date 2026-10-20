#!/usr/bin/env bash
# ============================================================================
# Arranque del relay CitiDirect:
#   1. Valida variables obligatorias.
#   2. Prepara carpetas persistentes en /home.
#   3. Genera .htpasswd (bcrypt) y la config de curl SIN dejar secretos en ps.
#   4. Arranca SSH (opcional), el forwarder (supervisado) y Apache.
# ============================================================================
set -euo pipefail

log() { printf '%s [entrypoint] %s\n' "$(date -u +%FT%TZ)" "$*"; }

# ---- 1. Variables obligatorias ---------------------------------------------
missing=0
for v in WEBDAV_USER WEBDAV_PASSWORD TARGET_ENDPOINT TARGET_USER TARGET_PASSWORD; do
    if [[ -z "${!v:-}" ]]; then
        log "ERROR: falta la variable de entorno $v"
        missing=1
    fi
done
[[ $missing -eq 0 ]] || exit 1

if [[ "$TARGET_ENDPOINT" != https://* ]]; then
    log "ERROR: TARGET_ENDPOINT debe usar https://"
    exit 1
fi

# ---- 2. Carpetas ------------------------------------------------------------
mkdir -p "$INBOX_DIR" "$STATE_DIR/sent" "$STATE_DIR/failed" "$STATE_DIR/retries"
# En /home de App Service el chown puede no aplicar; no es fatal.
chown -R www-data:www-data "$INBOX_DIR" 2>/dev/null || true
chmod 0770 "$INBOX_DIR" 2>/dev/null || true

# ---- 3. Credenciales --------------------------------------------------------
HTPASSWD_FILE=/usr/local/apache2/auth/.htpasswd
# -i: contraseña por stdin (no queda en la línea de comando); -B: bcrypt
printf '%s' "$WEBDAV_PASSWORD" | htpasswd -iBc "$HTPASSWD_FILE" "$WEBDAV_USER" >/dev/null 2>&1
chown root:www-data "$HTPASSWD_FILE"
chmod 0640 "$HTPASSWD_FILE"

# Config de curl para el forwarder (evita pasar -u usuario:password en ps).
CURL_CFG=/run/forwarder/curl.cfg
esc() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }
umask 077
printf 'user = "%s:%s"\n' "$(esc "$TARGET_USER")" "$(esc "$TARGET_PASSWORD")" > "$CURL_CFG"
umask 022
export CURL_CFG

# Los secretos ya no se necesitan en el entorno de los procesos hijos.
unset WEBDAV_PASSWORD TARGET_PASSWORD

# ---- 4. Servicios -----------------------------------------------------------
if [[ "${ENABLE_SSH:-true}" == "true" ]]; then
    ssh-keygen -A >/dev/null 2>&1 || true
    if /usr/sbin/sshd -t 2>/dev/null; then
        /usr/sbin/sshd
        log "SSH iniciado en el puerto 2222 (solo accesible vía Kudu)"
    else
        log "WARN: sshd_config inválido, SSH no se inicia"
    fi
fi

# Forwarder supervisado: si termina, se reinicia.
(
    while true; do
        /usr/local/bin/forwarder.sh || true
        log "WARN: forwarder terminó; reinicio en 5 s"
        sleep 5
    done
) &

log "Relay listo -> destino: $TARGET_ENDPOINT | bandeja: $INBOX_DIR"
exec httpd-foreground
