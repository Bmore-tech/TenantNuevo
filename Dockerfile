# ============================================================================
# CitiDirect WebDAV Relay
# ----------------------------------------------------------------------------
# Reemplazo endurecido de la imagen kevosmar/apache-citidirect.
#
# Flujo:
#   CitiDirect --WebDAV (Basic)--> /banco/  -> INBOX_DIR
#   forwarder.sh --PUT (Basic)--> TARGET_ENDPOINT/<archivo>  (API .NET /BANCO/)
#
# Diferencias con la imagen original:
#   - Sin credenciales en la imagen: todo llega por variables de entorno
#     (App Settings / referencias a Key Vault).
#   - .htpasswd con bcrypt, generado al arrancar y FUERA del DocumentRoot.
#   - Scripts fuera de htdocs; log a stdout (Log Stream de App Service).
#   - Bandeja persistente en /home (sobrevive reinicios del contenedor).
#   - Solo se envían archivos "estables" (sin escritura reciente).
#   - Reintentos con límite y carpeta failed/ para revisión manual.
#   - ServerTokens Prod / ServerSignature Off / TraceEnable Off.
# ============================================================================

# Recomendado: fijar por digest en producción, p. ej.
#   FROM httpd:2.4@sha256:<digest>
FROM httpd:2.4

# curl            -> reenvío de archivos a la API
# openssh-server  -> consola SSH de App Service (puerto 2222, solo vía Kudu)
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl openssh-server; \
    rm -rf /var/lib/apt/lists/*; \
    # Contraseña root estándar que exige App Service para SSH vía Kudu.
    # El puerto 2222 NO se expone a internet; solo es accesible desde Kudu.
    echo "root:Docker!" | chpasswd; \
    mkdir -p /run/sshd

COPY ssh/sshd_config /etc/ssh/sshd_config
COPY conf/httpd.conf /usr/local/apache2/conf/httpd.conf
COPY scripts/entrypoint.sh scripts/forwarder.sh /usr/local/bin/

RUN set -eux; \
    chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/forwarder.sh; \
    mkdir -p /usr/local/apache2/empty /usr/local/apache2/health \
             /usr/local/apache2/auth /var/lib/apache-dav /run/forwarder; \
    echo "OK" > /usr/local/apache2/health/index.html; \
    chown www-data:www-data /var/lib/apache-dav; \
    chmod 0750 /usr/local/apache2/auth /run/forwarder

# Valores por defecto (se sobrescriben con App Settings).
ENV INBOX_DIR=/home/citidirect/inbox \
    STATE_DIR=/home/citidirect \
    MAX_UPLOAD_BYTES=104857600 \
    POLL_INTERVAL=10 \
    STABLE_SECONDS=30 \
    MAX_RETRIES=20 \
    CURL_TIMEOUT=120 \
    KEEP_SENT=true \
    KEEP_SENT_DAYS=30 \
    ENABLE_SSH=true

EXPOSE 80 2222

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
