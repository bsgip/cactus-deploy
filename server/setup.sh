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
fi

# Re-assert every run so a pre-existing user still gets these.
mkdir -p "${HOME_DIR}"
chown "${USER_NAME}:${GROUP_NAME}" "${HOME_DIR}"
chmod 750 "${HOME_DIR}"
usermod -aG systemd-journal "${USER_NAME}"

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
socket_conf_changed=0

tmpfiles_content="d /run/podman 0770 root cactus - -"
if [[ "$(cat /etc/tmpfiles.d/podman.conf 2>/dev/null)" != "$tmpfiles_content" ]]; then
    echo "$tmpfiles_content" > /etc/tmpfiles.d/podman.conf
    systemd-tmpfiles --create /etc/tmpfiles.d/podman.conf
    socket_conf_changed=1
fi

mkdir -p /etc/systemd/system/podman.socket.d
override_content="[Socket]
SocketGroup=cactus
SocketMode=0770"
if [[ "$(cat /etc/systemd/system/podman.socket.d/override.conf 2>/dev/null)" != "$override_content" ]]; then
    echo "$override_content" > /etc/systemd/system/podman.socket.d/override.conf
    socket_conf_changed=1
fi

# Only restart when the config actually changed: restarting podman.socket replaces the
# socket inode, orphaning the bind mount of any already-running container (orchestrator,
# traefik), which then must be recreated. Re-running setup.sh must not trigger that.
if [[ "$socket_conf_changed" -eq 1 ]]; then
    systemctl daemon-reload
    systemctl restart podman.socket
else
    echo "    Socket group config already current, skipping restart."
fi

# Enable root socket as default socket for cactus user
container_host_line='export CONTAINER_HOST=unix:///run/podman/podman.sock'
grep -qxF "$container_host_line" "${HOME_DIR}/.bashrc" 2>/dev/null \
    || echo "$container_host_line" >> "${HOME_DIR}/.bashrc"

echo "==> Creating cactus-net..."
podman network exists cactus-net && echo "    Already exists, skipping." || podman network create cactus-net

# --------------------------------------------------------------------------- #
# Traefik                                                                     #
# --------------------------------------------------------------------------- #
echo "==> Starting Traefik..."


# Routes are discovered from container labels on cactus-net. Each teststack's runner carries the
# PathPrefix router plus a per-stack StripPrefix middleware, so teststack routing is created
# dynamically as the orchestrator spawns runners — no static Traefik config needed here.
#
# Skip if already running so re-runs don't drop in-flight teststack routing (podman rm -f traefik to refresh).
TRAEFIK_IMAGE="docker.io/library/traefik:v3"
if podman container exists traefik; then
    echo "    traefik already exists, skipping (podman rm -f traefik to force a refresh)."
else
    podman image pull "$TRAEFIK_IMAGE"
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
fi

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
echo "  4. Give the 'containers' user a subuid/subgid pool for userns=auto, then 'podman system migrate'."
echo "     IMPORTANT: rootful userns=auto draws IDs from the user named 'containers' (NOT root, NOT the"
echo "     cactus user). It carves ~65536 IDs per teststack container, so the pool must be large"
echo "     (~10M = ~160 container-slices) AND start clear of existing /etc/sub{u,g}id entries"
echo "     (overlapping ranges break userns isolation). Pick a start above all current ranges:"
echo "       # inspect existing allocations first:  cat /etc/subuid /etc/subgid"
echo "       for f in /etc/subuid /etc/subgid; do"
echo "         grep -q '^containers:' \"\$f\" || echo 'containers:11000000:10485760' >> \"\$f\""
echo "       done   # if a containers: line already exists but is too small, edit it by hand"
echo "       # some podman builds resolve 'containers' via NSS — if so: useradd --system --no-create-home containers"
echo "       podman system migrate"
echo "  5. Set up external postgres and run Alembic migrations"
echo "  6. Deploy containers: ./update.sh $ENV_FILE"
