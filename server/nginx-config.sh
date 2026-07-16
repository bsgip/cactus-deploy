#!/bin/bash
# Generates an nginx configuration file (via stdout) using the cactus.env values.
#
# Usage: nginx-config.sh <der|webui|http> [path-to-cactus.env]
#
#   der   — DER device-facing server block; mTLS + AES-128-CCM8; routes to Traefik
#   webui — operator-facing UI server block; standard TLS; routes to cactus-ui
#   http  — top-level http block (for templating /etc/nginx/nginx.conf)

set -euo pipefail

MODE="${1:-}"
ENV_FILE="${2:-./cactus.env}"

usage() {
    echo "Usage: sudo $0 <der|webui|http> [path-to-cactus.env]"
}

case "$MODE" in
    der|webui|http) ;;
    *)
        echo "ERROR: unknown mode: ${MODE:-<none>}"
        usage
        exit 1
        ;;
esac

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: env file not found: $ENV_FILE"
    usage
    exit 1
fi

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

export CACTUS_FQDN_REGEX="${CACTUS_FQDN//./\\.}"

# We only want specific variables to substitute into our nginx conf template
# (nginx has many of its own vars we don't want to touch)
#
# ONLY the variables defined here will substitute in the template below
ENVSUBST_VARS=$(cat <<'EOF'
${CACTUS_FQDN}
${CACTUS_FQDN_REGEX}
${CACTUS_CLIENT_NOTIFICATIONS_MOUNT_POINT}
${ENVOY_PREFIX}
${CERT_ENVOY_EE_FULLCHAIN_PATH}
${CERT_ENVOY_EE_KEY_PATH}
${CERT_SERCA_PATH}
EOF
)

# Lets do a bit of error checking - ensure each env variable in ENVSUBST_VARS actually has a value
declare -A seen
missing_vars=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    var_name="${line#\$\{}"    # strip leading ${
    var_name="${var_name%\}}"  # strip trailing }

    [[ -n "${seen[$var_name]:-}" ]] && continue
    seen[$var_name]=1

    if [[ -z "${!var_name:-}" ]]; then
        missing_vars+=("$var_name")
    fi
done <<< "$ENVSUBST_VARS"

if (( ${#missing_vars[@]} > 0 )); then
    echo "Error: the following required environment variables are not set or empty:" >&2
    printf '  - %s\n' "${missing_vars[@]}" >&2
    exit 1
fi

render_der() {
envsubst "$ENVSUBST_VARS" <<"EOF"
# --- DER Client domain(s)
#
# *.CACTUS_FQDN — DER device-facing; mTLS + AES-128-CCM8; routes to Traefik
#
# Traefik listens on 127.0.0.1:5001 (mapped from its container port 80).
#
# NOTE: AES-128-CCM8 (ECDHE-ECDSA-AES128-CCM8) is required by IEEE 2030.5.  It is not
# supported by standard OpenSSL builds.  nginx must be compiled against an OpenSSL version
# with CCM cipher support enabled (OpenSSL 1.1.1+ with -DOPENSSL_EXTRA_CCM or equivalent).
# Verify with: nginx -V 2>&1 | grep -o 'OpenSSL [0-9.]*'  and  openssl ciphers | grep CCM8
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    # Matches any subdomain depth of ${CACTUS_FQDN} (run-123.${CACTUS_FQDN}),
    # a.b.${CACTUS_FQDN}, etc.) but NOT ${CACTUS_FQDN} itself.
    server_name ~^.+\.${CACTUS_FQDN_REGEX}$;

    # Server certificate (from pki/create-cert.sh — dnsp-chain output, fullchain PEM)
    ssl_certificate     ${CERT_ENVOY_EE_FULLCHAIN_PATH};
    ssl_certificate_key ${CERT_ENVOY_EE_KEY_PATH};

    # TLS 1.2 + CCM8 supported (last) for 2030.5 clients, not enforced.
    ssl_protocols TLSv1.2;
    ssl_ciphers ECDH+AESGCM:ECDH+CHACHA20:ECDH+AES256:ECDH+AES128:!aDH:!ECDH+3DES:!RSA+3DES:!MD5:!DSS:ECDHE-ECDSA-AES128-CCM8;
    ssl_prefer_server_ciphers on;

    # mTLS against SERCA. Depth 3: device (MCA→MICA) or aggregator (PCA→ICA) → client cert.
    ssl_client_certificate ${CERT_SERCA_PATH};
    ssl_verify_client on;
    ssl_verify_depth 3;

    # Anything other than ${ENVOY_PREFIX} or /.well-known is not routed to the backend
    location / {
        return 404;
    }

    # Requests with the ${ENVOY_PREFIX} or /.well-known path prefix are proxied to
    # traeffic, using identical settings for both.
    location ~ ^(${ENVOY_PREFIX}|/\.well-known)(/.*)?$ {
        proxy_pass http://127.0.0.1:5001;
        proxy_http_version 1.1;

        # All incoming headers are forwarded by default; these are
        # additionally set/overridden on top of that.
        proxy_pass_request_headers on;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        # Pass URL-encoded client certificate to envoy (CERT_HEADER=ssl-client-cert)
        proxy_set_header ssl-client-cert   $ssl_client_escaped_cert;
        # Epoch time when nginx started proxying upstream; cactus-runner records this
        proxy_set_header X-Request-Start   "t=${msec}";

        proxy_read_timeout 300;
        proxy_send_timeout 300;
    }
}

# Redirect HTTP → HTTPS
server {
    listen 80;
    server_name ~^.+\.${CACTUS_FQDN_REGEX}$;
    return 301 https://$host$request_uri;
}
EOF
}

render_webui() {
envsubst "$ENVSUBST_VARS" <<"EOF"
# --- Web UI domain
#
# CACTUS_FQDN — operator-facing UI; standard TLS; routes to cactus-ui
#
# cactus-ui listens on 127.0.0.1:5000 (mapped from its container port 8080).
# cactus-client-notifications listens on 127.0.0.1:5002 (mapped from its container port 8080).
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name ${CACTUS_FQDN};

    # Let's Encrypt certificate (renewed via certbot; paths are standard certbot output)
    ssl_certificate     /etc/letsencrypt/live/${CACTUS_FQDN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${CACTUS_FQDN}/privkey.pem;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;


    ssl_protocols TLSv1.2;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    proxy_read_timeout 300;
    proxy_send_timeout 300;

    # cactus-client-notifications webhook endpoint
    location ${CACTUS_CLIENT_NOTIFICATIONS_MOUNT_POINT} {
        proxy_pass http://127.0.0.1:5002;
        proxy_http_version 1.1;
        proxy_set_header Host            $host;
        proxy_set_header X-Real-IP       $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # Everything else goes to the cactus-ui Flask app
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}

# Redirect HTTP → HTTPS
server {
    listen 80;
    server_name ${CACTUS_FQDN};
    return 301 https://$host$request_uri;
}
EOF
}

render_http() {
    # A "default" nginx.conf http block. Not yet templated against cactus.env —
    # placeholder until the top-level nginx.conf needs its own substituted values.
    cat <<"EOF"
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    sendfile           on;
    keepalive_timeout  65;

    gzip on;

    ssl_protocols TLSv1.2 TLSv1.3;

    # Logging
    log_format journal_plain '[$time_iso8601] $remote_addr "$request_method $request_uri" $status ${request_time}s cipher="$ssl_cipher" received=$request_length sent=$bytes_sent';
    access_log /var/log/nginx/access.log journal_plain;
    error_log /var/log/nginx/error.log warn;

    include /etc/nginx/sites-enabled/*;
}
EOF
}

case "$MODE" in
    der)   render_der ;;
    webui) render_webui ;;
    http)  render_http ;;
esac
