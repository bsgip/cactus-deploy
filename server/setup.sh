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

echo "==> Ensuring podman recovers on reboot"
systemctl enable podman-restart.service

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

    # The restart above just replaced the socket inode, so any container with a bind mount
    # of the old one (traefik) is now silently talking to a dead handle. It won't error, it'll
    # just stop seeing container events forever. Force it to be recreated against the fresh
    # socket further down instead of leaving it running on borrowed time.
    if podman container exists traefik; then
        echo "    podman.socket was replaced: removing traefik so it gets recreated against the fresh socket."
        podman rm -f traefik
    fi
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
echo "     cactus user). It carves ONE slice per teststack POD, sized by podman to the pod's max image"
echo "     UID/GID (measured ~1024 today, but can grow if an image switches to a high-UID base). Pool"
echo "     must be large (1048576 = headroom past 200+ concurrent tests) AND start clear of existing"
echo "     /etc/sub{u,g}id entries (overlapping ranges break userns isolation). Pick a start above all"
echo "     current ranges:"
echo "       # inspect existing allocations first:  cat /etc/subuid /etc/subgid"
echo "       for f in /etc/subuid /etc/subgid; do"
echo "         grep -q '^containers:' \"\$f\" || echo 'containers:11000000:1048576' >> \"\$f\""
echo "       done   # if a containers: line already exists but is too small, edit it by hand"
echo "       # some podman builds resolve 'containers' via NSS — if so: useradd --system --no-create-home containers"
echo "       podman system migrate"
echo "  5. Set up external postgres and run Alembic migrations"
echo "  6. Deploy containers: ./update.sh $ENV_FILE"
