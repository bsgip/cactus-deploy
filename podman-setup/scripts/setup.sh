#!/bin/bash
# One-shot infrastructure setup for the Cactus platform (Podman-based deployment).
# Run as root on a fresh Ubuntu 24.04 host.
# Requires a populated cactus.env in the same directory as this script.
# Usage: sudo ./setup.sh ./cactus.env

set -euo pipefail

ENV_FILE="${1:-./cactus.env}"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: env file not found: $ENV_FILE"
    echo "Usage: sudo $0 <path-to-cactus.env>"
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# --------------------------------------------------------------------------- #
# 1. Podman                                                                    #
# --------------------------------------------------------------------------- #
echo "==> Installing Podman..."
apt-get update -q
apt-get install --no-install-recommends -y podman

echo "==> Enabling Podman socket (rootful)..."
systemctl enable --now podman.socket
echo "    Socket: $(ls -la /run/podman/podman.sock)"

# --------------------------------------------------------------------------- #
# 2. Network                                                                   #
# --------------------------------------------------------------------------- #
echo "==> Creating cactus-net..."
podman network exists cactus-net && echo "    Already exists, skipping." || podman network create cactus-net

# --------------------------------------------------------------------------- #
# 3. Traefik                                                                   #
# --------------------------------------------------------------------------- #
echo "==> Starting Traefik..."


# Routes are discovered from container labels on cactus-net. Each teststack's runner carries the
# PathPrefix router plus a per-stack StripPrefix middleware, so teststack routing is created
# dynamically as the orchestrator spawns runners — no static Traefik config needed here.
podman rm -f traefik 2>/dev/null || true
podman run -d \
    --name traefik \
    --restart always \
    --network cactus-net \
    -v /run/podman/podman.sock:/var/run/docker.sock:z \
    -p 127.0.0.1:80:80 \
    traefik:v3 \
        --providers.docker=true \
        --providers.docker.endpoint=unix:///var/run/docker.sock \
        --providers.docker.exposedbydefault=false \
        --providers.docker.network=cactus-net \
        --entrypoints.web.address=:80

# --------------------------------------------------------------------------- #
# 4. Certificate directories                                                   #
# --------------------------------------------------------------------------- #
echo "==> Creating certificate directory /etc/cactus/pki..."
mkdir -p /etc/cactus/pki
chmod 700 /etc/cactus/pki
echo "    Place PKI artefacts here before starting the orchestrator."
echo "    See ../pki/README.md and ../pki/create-cert.sh."

# --------------------------------------------------------------------------- #
# 5. nginx (CCM8 cipher support required)                                      #
# --------------------------------------------------------------------------- #
echo "==> Installing nginx..."
apt-get install --no-install-recommends -y nginx certbot python3-certbot-nginx

echo ""
echo "    NOTE: AES-128-CCM8 support requires nginx compiled against an OpenSSL"
echo "    build with CCM enabled.  Verify with:"
echo "      openssl ciphers | grep -c CCM8"
echo "    If the count is 0, install a custom nginx/OpenSSL build before proceeding."
echo ""

echo "==> Generating nginx config..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_TEMPLATE="$SCRIPT_DIR/../nginx/nginx.conf"
NGINX_DEST="/etc/nginx/sites-available/cactus"

# shellcheck disable=SC2016
envsubst '${TEST_EXECUTION_FQDN} ${TEST_ORCHESTRATION_FQDN} ${CACTUS_CLIENT_NOTIFICATIONS_MOUNT_POINT}' \
    < "$NGINX_TEMPLATE" > "$NGINX_DEST"

ln -sf "$NGINX_DEST" /etc/nginx/sites-enabled/cactus
rm -f /etc/nginx/sites-enabled/default

echo "    Written to $NGINX_DEST"
echo "    Place server certificates at /etc/nginx/certs/ before enabling nginx."
echo "    Then run: certbot --nginx -d ${TEST_ORCHESTRATION_FQDN}"

# --------------------------------------------------------------------------- #
# 6. Pre-pull teststack images                                                 #
# --------------------------------------------------------------------------- #
echo "==> Pre-pulling teststack images..."
# Pull all unique images referenced in PODMAN_TESTSTACK_IMAGES.
# jq is used to flatten the image map; install it if missing.
if command -v jq &>/dev/null; then
    echo "$PODMAN_TESTSTACK_IMAGES" | jq -r '.[] | .[]' | sort -u | while read -r image; do
        echo "    Pulling $image ..."
        podman pull "$image"
    done
else
    echo "    jq not found — skipping automatic image pre-pull."
    echo "    Install jq and re-run, or pull images manually with 'podman pull <image>'."
fi

# --------------------------------------------------------------------------- #
# 7. Done                                                                      #
# --------------------------------------------------------------------------- #
echo ""
echo "==> Infrastructure setup complete."
echo ""
echo "Next steps:"
echo "  1. Generate PKI artefacts:  cd ../pki && ./create-cert.sh ..."
echo "  2. Copy certs to /etc/cactus/pki/ and /etc/nginx/certs/"
echo "  3. Obtain Let's Encrypt cert: certbot --nginx -d ${TEST_ORCHESTRATION_FQDN}"
echo "  4. Set up external postgres and run Alembic migrations"
echo "  5. Deploy containers: ./update.sh $ENV_FILE"
