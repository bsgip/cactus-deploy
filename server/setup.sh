#!/bin/bash
# One-shot infrastructure setup for the Cactus platform (Podman-based deployment).
# Run as root on a fresh Ubuntu host.
# Requires a populated cactus.env in the same directory as this script.
# Usage: sudo ./setup.sh ./cactus.env

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: this script must be run as root (try: sudo $0)" >&2
    exit 1
fi

ENV_FILE="${1:-./cactus.env}"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: env file not found: $ENV_FILE"
    echo "Usage: sudo $0 <path-to-cactus.env>"
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# --------------------------------------------------------------------------- #
# User                                                                        #
# --------------------------------------------------------------------------- #

GROUP_NAME="cactus"
USER_NAME="cactus"
HOME_DIR="/localhome/${USER_NAME}"

echo "==> Ensuring User '${USER_NAME}' and Group '${GROUP_NAME}'..."

if getent group "${GROUP_NAME}" >/dev/null 2>&1; then
    echo "Group '${GROUP_NAME}' already exists, skipping."
else
    echo "Creating group '${GROUP_NAME}' ..."
    groupadd "${GROUP_NAME}"
fi

if getent passwd "${USER_NAME}" >/dev/null 2>&1; then
    echo "User '${USER_NAME}' already exists, skipping creation."
else
    echo "Creating user '${USER_NAME}' with home directory ${HOME_DIR} ..."
    useradd \
        --create-home \
        --home-dir "${HOME_DIR}" \
        --gid "${GROUP_NAME}" \
        --shell /bin/bash \
        "${USER_NAME}"

    mkdir -p "${HOME_DIR}"
    chown "${USER_NAME}:${GROUP_NAME}" "${HOME_DIR}"
    chmod 750 "${HOME_DIR}"
fi

# --------------------------------------------------------------------------- #
# Podman                                                                      #
# --------------------------------------------------------------------------- #
echo "==> Installing Podman..."
apt-get update -q
# podman alone is not enough for this deployment; pin the critical companions explicitly rather than
# relying on apt Recommends (which a --no-install-recommends install would silently skip):
#   aardvark-dns + netavark : container name resolution / networking on cactus-net
#   catatonit               : PID 1 init for pod infra containers; `podman pod create` fails without it
# (uidmap, for userns=auto, still comes via Recommends since we don't pass --no-install-recommends.)
apt-get install -y podman aardvark-dns netavark catatonit

echo "==> Enabling Podman socket (rootful)..."
systemctl enable --now podman.socket
echo "    Socket: $(ls -la /run/podman/podman.sock)"

echo "==> Adding podman socket to cactus group"
tee /etc/tmpfiles.d/podman.conf <<EOF
d /run/podman 0770 root cactus - -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/podman.conf
mkdir -p /etc/systemd/system/podman.socket.d
tee /etc/systemd/system/podman.socket.d/override.conf <<EOF
[Socket]
SocketGroup=cactus
SocketMode=0770
EOF
systemctl daemon-reload
systemctl restart podman.socket

# Enable root socket as default socket for cactus user
echo 'export CONTAINER_HOST=unix:///run/podman/podman.sock' >> "${HOME_DIR}/.bashrc"

echo "==> Creating cactus-net..."
podman network exists cactus-net && echo "    Already exists, skipping." || podman network create cactus-net

# --------------------------------------------------------------------------- #
# Traefik                                                                     #
# --------------------------------------------------------------------------- #
echo "==> Starting Traefik..."


# Routes are discovered from container labels on cactus-net. Each teststack's runner carries the
# PathPrefix router plus a per-stack StripPrefix middleware, so teststack routing is created
# dynamically as the orchestrator spawns runners — no static Traefik config needed here.
TRAEFIK_IMAGE="docker.io/library/traefik:v3"
podman image pull "$TRAEFIK_IMAGE"
podman rm -f traefik 2>/dev/null || true
podman run -d \
    --name traefik \
    --restart always \
    --network cactus-net \
    -v /run/podman/podman.sock:/var/run/docker.sock:z \
    -p 127.0.0.1:5001:80 \
    "$TRAEFIK_IMAGE" \
        --providers.docker=true \
        --providers.docker.endpoint=unix:///var/run/docker.sock \
        --providers.docker.exposedbydefault=false \
        --providers.docker.network=cactus-net \
        --entrypoints.web.address=:80

# --------------------------------------------------------------------------- #
# Certificate directories                                                     #
# --------------------------------------------------------------------------- #
echo "==> Creating certificate directory /etc/cactus/pki..."
mkdir -p /etc/cactus/pki
# 750 (not 700): the orchestrator runs as non-root 'appuser' with supplementary group 'cactus'
# (see --group-add in update.sh) and must be able to traverse this dir to read the MICA signing key.
chmod 750 /etc/cactus/pki
chown -R $USER_NAME:$GROUP_NAME /etc/cactus
echo "    Place PKI artefacts here before starting the orchestrator (owned ${USER_NAME}:${GROUP_NAME},"
echo "    dirs 750 / files 640 so the orchestrator's 'cactus' group can read the keys)."
echo "    See ../pki/README.md and ../pki/create-cert.sh."

# --------------------------------------------------------------------------- #
# nginx / TLS edge — intentionally NOT handled here                           #
# --------------------------------------------------------------------------- #
# The device-facing vhost requires AES-128-CCM8 (IEEE 2030.5), which stock
# distro nginx cannot provide — nginx is custom-compiled against a CCM-capable
# OpenSSL and installed out of band. This script does not install, configure,
# or reload nginx, and does not issue TLS certs. Render the config template
# yourself when placing it into your custom nginx layout:
#   envsubst '${TEST_EXECUTION_FQDN} ${TEST_ORCHESTRATION_FQDN} ${CACTUS_CLIENT_NOTIFICATIONS_MOUNT_POINT}' \
#       < ../nginx/nginx.conf > <your-nginx-conf-path>


# --------------------------------------------------------------------------- #
# Done                                                                        #
# --------------------------------------------------------------------------- #
echo ""
echo "==> Infrastructure setup complete."
echo ""
echo "Next steps:"
echo "  1. Generate PKI artefacts:  cd ../pki && ./create-cert.sh ..."
echo "  2. Copy orchestrator certs to /etc/cactus/pki/"
echo "  3. Install your custom-compiled (CCM8-capable) nginx, place its TLS certs,"
echo "     and render ../nginx/nginx.conf into its config (see note above). Issue"
echo "     the orchestration-domain cert (mechanism TBD), then reload nginx."
echo "  4. Add root subuid/subgid for userns=auto, then 'podman system migrate':"
echo "       grep -q '^root:' /etc/subuid || echo 'root:100000:1048576' >> /etc/subuid"
echo "       grep -q '^root:' /etc/subgid || echo 'root:100000:1048576' >> /etc/subgid"
echo "  5. Set up external postgres and run Alembic migrations"
echo "  6. Deploy containers: ./update.sh $ENV_FILE"
