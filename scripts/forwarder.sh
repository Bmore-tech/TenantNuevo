#!/usr/bin/env bash
# ============================================================================
# Reenvía a la API (.NET /BANCO/) los archivos que CitiDirect deja por WebDAV.
#
# - Solo envía archivos "estables" (sin modificar en STABLE_SECONDS) para no
#   mandar un archivo que todavía se está subiendo.
# - Ignora ocultos y temporales (.*, *.tmp, *.part).
# - Éxito (200/201/204): mueve a sent/ (KEEP_SENT=true) o elimina.
# - Error: reintenta; al llegar a MAX_RETRIES mueve a failed/ para revisión.
# - Log a stdout -> Log Stream de App Service.
#
# IMPORTANTE: ejecutar con 1 sola instancia del App Service (sin scale-out),
# porque la bandeja en /home es compartida entre instancias.
# ============================================================================
set -uo pipefail

: "${TARGET_ENDPOINT:?}" "${CURL_CFG:?}" "${INBOX_DIR:?}" "${STATE_DIR:?}"
POLL_INTERVAL=${POLL_INTERVAL:-10}
STABLE_SECONDS=${STABLE_SECONDS:-30}
MAX_RETRIES=${MAX_RETRIES:-20}
CURL_TIMEOUT=${CURL_TIMEOUT:-120}
KEEP_SENT=${KEEP_SENT:-true}
KEEP_SENT_DAYS=${KEEP_SENT_DAYS:-30}

SENT_DIR="$STATE_DIR/sent"
FAILED_DIR="$STATE_DIR/failed"
RETRY_DIR="$STATE_DIR/retries"
ENDPOINT="${TARGET_ENDPOINT%/}"

log() { printf '%s [forwarder] %s\n' "$(date -u +%FT%TZ)" "$*"; }

# Codifica el nombre del archivo para la URL (espacios, acentos, etc.)
urlencode() {
    local LC_ALL=C s="$1" out="" c i hex
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
        esac
    done
    printf '%s' "$out"
}

send_file() {
    local file="$1" name code retries_file retries
    name="$(basename "$file")"
    retries_file="$RETRY_DIR/$name.count"

    code=$(curl -sS -o /dev/null -w '%{http_code}' \
                --config "$CURL_CFG" \
                --max-time "$CURL_TIMEOUT" \
                -X PUT -T "$file" \
                "$ENDPOINT/$(urlencode "$name")" 2>/dev/null) || code="000"

    if [[ "$code" == "200" || "$code" == "201" || "$code" == "204" ]]; then
        if [[ "$KEEP_SENT" == "true" ]]; then
            mv -f "$file" "$SENT_DIR/$(date -u +%Y%m%dT%H%M%SZ)_$name"
        else
            rm -f "$file"
        fi
        rm -f "$retries_file"
        log "OK   $name (HTTP $code)"
        return 0
    fi

    # Errores 4xx del cliente: son permanentes (p. ej. 400 archivo vacio,
    # 401/403 auth, 404/409/413/415/422). Reintentarlos 360 veces no los
    # arregla y satura el backend (lentitud). Se mueven a failed/ de inmediato.
    case "$code" in
        400|401|403|404|409|413|415|422)
            mv -f "$file" "$FAILED_DIR/$(date -u +%Y%m%dT%H%M%SZ)_$name"
            rm -f "$retries_file"
            log "FAIL $name (HTTP $code) permanente (4xx) -> movido a failed/ sin reintentar"
            return 1
            ;;
    esac

    retries=$(( $(cat "$retries_file" 2>/dev/null || echo 0) + 1 ))
    echo "$retries" > "$retries_file"

    if (( retries >= MAX_RETRIES )); then
        mv -f "$file" "$FAILED_DIR/$(date -u +%Y%m%dT%H%M%SZ)_$name"
        rm -f "$retries_file"
        log "FAIL $name (HTTP $code) -> movido a failed/ tras $retries intentos"
    else
        log "RETRY $name (HTTP $code) intento $retries/$MAX_RETRIES"
    fi
    return 1
}

log "Iniciando. Bandeja=$INBOX_DIR Destino=$ENDPOINT Intervalo=${POLL_INTERVAL}s"
last_cleanup=0

while true; do
    now=$(date +%s)

    shopt -s nullglob
    for file in "$INBOX_DIR"/*; do
        name="$(basename "$file")"
        [[ -f "$file" ]] || continue
        [[ "$name" == .* || "$name" == *.tmp || "$name" == *.part ]] && continue

        mtime=$(stat -c %Y "$file" 2>/dev/null) || continue
        (( now - mtime >= STABLE_SECONDS )) || continue

        send_file "$file"
    done
    shopt -u nullglob

    # Limpieza diaria de sent/
    if [[ "$KEEP_SENT" == "true" ]] && (( now - last_cleanup > 86400 )); then
        find "$SENT_DIR" -type f -mtime +"$KEEP_SENT_DAYS" -delete 2>/dev/null || true
        last_cleanup=$now
    fi

    sleep "$POLL_INTERVAL"
done
