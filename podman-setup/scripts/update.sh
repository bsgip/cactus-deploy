#!/bin/bash
# Deploy/update core Cactus containers (orchestrator, UI, client-notifications).
# Teststack containers are managed at runtime by the orchestrator via the Podman socket.
# Run as root.
# Usage: sudo ./update.sh ./cactus.env

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
# Image registry login                                                         #
# --------------------------------------------------------------------------- #
# Uncomment and set credentials if using a private registry.
# podman login cactusimageregistry.azurecr.io \
#     --username "${REGISTRY_USERNAME}" \
#     --password "${REGISTRY_PASSWORD}"

# --------------------------------------------------------------------------- #
# Pull latest images                                                           #
# --------------------------------------------------------------------------- #
echo "==> Pulling images..."
podman pull "$CACTUS_ORCHESTRATOR_IMAGE"
podman pull "$CACTUS_UI_IMAGE"
podman pull "$CACTUS_CLIENT_NOTIFICATIONS_IMAGE"

# --------------------------------------------------------------------------- #
# cactus-orchestrator                                                          #
# --------------------------------------------------------------------------- #
echo "==> Deploying cactus-orchestrator..."
podman rm -f cactus-orchestrator 2>/dev/null || true
podman run -d \
    --name cactus-orchestrator \
    --restart always \
    --network cactus-net \
    -p 127.0.0.1:8000:8080 \
    -v /run/podman/podman.sock:/run/podman/podman.sock:z \
    -v "${CERT_SERCA_PATH}:${CERT_SERCA_PATH}:ro,z" \
    -v "${CERT_MCA_PATH}:${CERT_MCA_PATH}:ro,z" \
    -v "${CERT_MICA_CRT_PATH}:${CERT_MICA_CRT_PATH}:ro,z" \
    -v "${CERT_MICA_KEY_PATH}:${CERT_MICA_KEY_PATH}:ro,z" \
    -e ORCHESTRATOR_DATABASE_URL="${ORCHESTRATOR_DATABASE_URL}" \
    -e TEST_EXECUTION_FQDN="${TEST_EXECUTION_FQDN}" \
    -e JWTAUTH_JWKS_URL="${JWTAUTH_JWKS_URL}" \
    -e JWTAUTH_ISSUER="${JWTAUTH_ISSUER}" \
    -e JWTAUTH_AUDIENCE="${JWTAUTH_AUDIENCE}" \
    -e IGNORED_CSIP_AUS_VERSIONS="${IGNORED_CSIP_AUS_VERSIONS}" \
    -e PODMAN_SOCKET="${PODMAN_SOCKET}" \
    -e PODMAN_NETWORK="${PODMAN_NETWORK}" \
    -e PODMAN_RUNNER_PORT="${PODMAN_RUNNER_PORT}" \
    -e PODMAN_TESTSTACK_IMAGES="${PODMAN_TESTSTACK_IMAGES}" \
    -e CERT_SERCA_PATH="${CERT_SERCA_PATH}" \
    -e CERT_MCA_PATH="${CERT_MCA_PATH}" \
    -e CERT_MICA_CRT_PATH="${CERT_MICA_CRT_PATH}" \
    -e CERT_MICA_KEY_PATH="${CERT_MICA_KEY_PATH}" \
    "$CACTUS_ORCHESTRATOR_IMAGE"

# --------------------------------------------------------------------------- #
# cactus-ui                                                                    #
# --------------------------------------------------------------------------- #
echo "==> Deploying cactus-ui..."
podman rm -f cactus-ui 2>/dev/null || true
podman run -d \
    --name cactus-ui \
    --restart always \
    --network cactus-net \
    -p 127.0.0.1:5000:8080 \
    -e AUTH0_CLIENT_ID="${AUTH0_CLIENT_ID}" \
    -e AUTH0_CLIENT_SECRET="${AUTH0_CLIENT_SECRET}" \
    -e AUTH0_DOMAIN="${AUTH0_DOMAIN}" \
    -e APP_SECRET_KEY="${APP_SECRET_KEY}" \
    -e CACTUS_ORCHESTRATOR_BASEURL="${CACTUS_ORCHESTRATOR_BASEURL}" \
    -e CACTUS_ORCHESTRATOR_AUDIENCE="${CACTUS_ORCHESTRATOR_AUDIENCE}" \
    -e CACTUS_PLATFORM_VERSION="${CACTUS_PLATFORM_VERSION}" \
    -e CACTUS_PLATFORM_SUPPORT_EMAIL="${CACTUS_PLATFORM_SUPPORT_EMAIL}" \
    -e CACTUS_ORCHESTRATOR_REQUEST_TIMEOUT_DEFAULT="180" \
    -e CACTUS_ORCHESTRATOR_REQUEST_TIMEOUT_SPAWN="300" \
    -e BANNER_MESSAGE="${BANNER_MESSAGE}" \
    -e LOGIN_BANNER_MESSAGE="${LOGIN_BANNER_MESSAGE}" \
    "$CACTUS_UI_IMAGE"

# --------------------------------------------------------------------------- #
# cactus-client-notifications                                                  #
# --------------------------------------------------------------------------- #
echo "==> Deploying cactus-client-notifications..."
podman rm -f cactus-client-notifications 2>/dev/null || true
podman run -d \
    --name cactus-client-notifications \
    --restart always \
    --network cactus-net \
    -p 127.0.0.1:5001:8080 \
    -e SERVER_URL="${CACTUS_CLIENT_NOTIFICATIONS_SERVER_URL}" \
    -e MOUNT_POINT="${CACTUS_CLIENT_NOTIFICATIONS_MOUNT_POINT}" \
    "$CACTUS_CLIENT_NOTIFICATIONS_IMAGE"

echo ""
echo "==> Update complete.  Running containers:"
podman ps --filter name=cactus
