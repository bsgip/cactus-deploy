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


# Collect every environment variable prefixed with CACTUS_IMAGE__ and turn
# each one into a "-e NAME=VALUE" argument for podman run.
#
# ${!CACTUS_IMAGE__@} is bash indirect expansion: it expands to the *names*
# of all currently-set variables starting with that prefix. This avoids
# parsing `env` output, so values containing '=', spaces, or newlines are
# handled safely (since we build an array, not a string).
cactus_image_env_args=()
for var_name in "${!CACTUS_IMAGE__@}"; do
    cactus_image_env_args+=(-e "${var_name}=${!var_name}")
done

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
# Pre-pull teststack images                                                    #
# --------------------------------------------------------------------------- #
# The orchestrator lazily pulls any missing teststack image on first spawn, but pre-pulling here keeps
# the first post-release spawn warm (the orchestrator is recreated below each release anyway). Fresh tag
# per release, so this only fetches the new tags; old tags stay cached until pruned (see README).

# Enumerate every CACTUS_IMAGE__* env var and pull each one's value as a
# podman image, skipping any that already exist locally. Variables whose
# NAME ends with __CSIP_AUS_VERSION are skipped entirely - they're version
# labels, not image references.
 
pulled=0
already_present=0
 
for var_name in "${!CACTUS_IMAGE__@}"; do
    if [[ "$var_name" == *__CSIP_AUS_VERSION ]]; then
        echo "Skipping ${var_name} - version label, not an image"
        continue
    fi
 
    image="${!var_name}"
 
    if podman image exists "$image"; then
        echo "Already present, skipping pull: ${image} (${var_name})"
        already_present=$((already_present + 1))
    else
        echo "Pulling: ${image} (${var_name})"
        podman pull "$image"
        pulled=$((pulled + 1))
    fi
done

echo "Done. Pulled: ${pulled}, already present: ${already_present}"
 

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
    --group-add "$(getent group cactus | cut -d: -f3)" \
    -v /run/podman/podman.sock:/run/podman/podman.sock:z \
    -v "${CERT_SERCA_PATH}:${CERT_SERCA_PATH}:ro,z" \
    -v "${CERT_DEVICE_MCA_PATH}:${CERT_DEVICE_MCA_PATH}:ro,z" \
    -v "${CERT_DEVICE_MICA_CRT_PATH}:${CERT_DEVICE_MICA_CRT_PATH}:ro,z" \
    -v "${CERT_DEVICE_MICA_KEY_PATH}:${CERT_DEVICE_MICA_KEY_PATH}:ro,z" \
    -v "${CERT_AGG_PCA_PATH}:${CERT_AGG_PCA_PATH}:ro,z" \
    -v "${CERT_AGG_ICA_CRT_PATH}:${CERT_AGG_ICA_CRT_PATH}:ro,z" \
    -v "${CERT_AGG_ICA_KEY_PATH}:${CERT_AGG_ICA_KEY_PATH}:ro,z" \
    -v "${CERT_ENVOY_EE_FULLCHAIN_PATH}:${CERT_ENVOY_EE_FULLCHAIN_PATH}:ro,z" \
    -v "${CERT_ENVOY_EE_KEY_PATH}:${CERT_ENVOY_EE_KEY_PATH}:ro,z" \
    -e ORCHESTRATOR_DATABASE_URL="${ORCHESTRATOR_DATABASE_URL}" \
    -e CACTUS_FQDN="${CACTUS_FQDN}" \
    -e ENVOY_PREFIX="${ENVOY_PREFIX}" \
    -e JWTAUTH_JWKS_URL="${JWTAUTH_JWKS_URL}" \
    -e JWTAUTH_ISSUER="${JWTAUTH_ISSUER}" \
    -e JWTAUTH_AUDIENCE="${JWTAUTH_AUDIENCE}" \
    -e IGNORED_CSIP_AUS_VERSIONS="${IGNORED_CSIP_AUS_VERSIONS}" \
    -e PODMAN_SOCKET="${PODMAN_SOCKET}" \
    -e PODMAN_NETWORK="${PODMAN_NETWORK}" \
    -e PODMAN_RUNNER_PORT="${PODMAN_RUNNER_PORT}" \
    -e CERT_SERCA_PATH="${CERT_SERCA_PATH}" \
    -e CERT_DEVICE_MCA_PATH="${CERT_DEVICE_MCA_PATH}" \
    -e CERT_DEVICE_MICA_CRT_PATH="${CERT_DEVICE_MICA_CRT_PATH}" \
    -e CERT_DEVICE_MICA_KEY_PATH="${CERT_DEVICE_MICA_KEY_PATH}" \
    -e CERT_AGG_PCA_PATH="${CERT_AGG_PCA_PATH}" \
    -e CERT_AGG_ICA_CRT_PATH="${CERT_AGG_ICA_CRT_PATH}" \
    -e CERT_AGG_ICA_KEY_PATH="${CERT_AGG_ICA_KEY_PATH}" \
    -e CERT_ENVOY_EE_FULLCHAIN_PATH="${CERT_ENVOY_EE_FULLCHAIN_PATH}" \
    -e CERT_ENVOY_EE_KEY_PATH="${CERT_ENVOY_EE_KEY_PATH}" \
    --log-driver=journald \
    --log-opt=tag=cactus-orchestrator \
    "${cactus_image_env_args[@]}" \
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
    --log-driver=journald \
    --log-opt=tag=cactus-ui \
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
    -p 127.0.0.1:5002:8080 \
    -e SERVER_URL="${CACTUS_CLIENT_NOTIFICATIONS_SERVER_URL}" \
    -e MOUNT_POINT="${CACTUS_CLIENT_NOTIFICATIONS_MOUNT_POINT}" \
    --log-driver=journald \
    --log-opt=tag=cactus-client-notifications \
    "$CACTUS_CLIENT_NOTIFICATIONS_IMAGE"

echo ""
echo "==> Update complete.  Running containers:"
podman ps --filter name=cactus
