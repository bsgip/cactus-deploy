#!/bin/bash
# Stage the create-cert.sh PKI artefacts into the host paths the orchestrator reads (the CERT_* paths
# in cactus.env), with cactus:cactus ownership and least-privilege modes. Copies ONLY what the
# orchestrator needs - never the SERCA / MCA / PCA / DNSP-ICA private keys.
# Assumes create-cert.sh was run per pki/README §1 (chain ids device-chain / aggregator-chain / envoy).
# Run as root.
# Usage: sudo ./stage-certs.sh <create-cert-output-dir> [cactus.env]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${1:-}"
ENV_FILE="${2:-${SCRIPT_DIR}/../server/cactus.env}"

USER_NAME="cactus"
GROUP_NAME="cactus"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: must run as root (chown to ${USER_NAME}). Try: sudo $0 ..." >&2
    exit 1
fi

if [[ -z "$SRC_DIR" || ! -d "$SRC_DIR" ]]; then
    echo "ERROR: create-cert output dir not found: '${SRC_DIR}'"
    echo "Usage: sudo $0 <create-cert-output-dir> [cactus.env]"
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: env file not found: ${ENV_FILE}"
    echo "Usage: sudo $0 <create-cert-output-dir> [cactus.env]"
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# Allowlist: <source-relative-path> <dest CERT_* var> <mode>. This IS the least-privilege filter -
# the SERCA / MCA / PCA / DNSP-ICA private keys are deliberately absent.
MAPPINGS=(
    "serca/serca.cert.pem          CERT_SERCA_PATH              644"
    "device-chain/MCA.cert.pem     CERT_DEVICE_MCA_PATH         644"
    "device-chain/MICA.cert.pem    CERT_DEVICE_MICA_CRT_PATH    644"
    "device-chain/MICA.key.pem     CERT_DEVICE_MICA_KEY_PATH    640"
    "aggregator-chain/pca.cert.pem CERT_AGG_PCA_PATH            644"
    "aggregator-chain/ica.cert.pem CERT_AGG_ICA_CRT_PATH        644"
    "aggregator-chain/ica.key.pem  CERT_AGG_ICA_KEY_PATH        640"
    "envoy/envoy.fullchain.pem     CERT_ENVOY_EE_FULLCHAIN_PATH 644"
    "envoy/envoy.key.pem           CERT_ENVOY_EE_KEY_PATH       640"
)

# Validate everything up front so we fail with a full list rather than half-staged.
errors=()
for row in "${MAPPINGS[@]}"; do
    read -r rel var _mode <<< "$row"
    [[ -f "${SRC_DIR}/${rel}" ]] || errors+=("missing source: ${SRC_DIR}/${rel}")
    [[ -n "${!var:-}" ]] || errors+=("unset/empty in ${ENV_FILE}: ${var}")
done
if (( ${#errors[@]} > 0 )); then
    echo "ERROR:" >&2
    printf '  - %s\n' "${errors[@]}" >&2
    exit 1
fi

echo "==> Staging PKI from '${SRC_DIR}' into the cactus.env CERT_* paths..."
for row in "${MAPPINGS[@]}"; do
    read -r rel var mode <<< "$row"
    dest="${!var}"
    # install -d also (re)applies 750 cactus:cactus to an existing dir, fixing any drift.
    install -d -m 750 -o "$USER_NAME" -g "$GROUP_NAME" "$(dirname "$dest")"
    install -m "$mode" -o "$USER_NAME" -g "$GROUP_NAME" "${SRC_DIR}/${rel}" "$dest"
    echo "    ${rel}  ->  ${dest}  (${mode})"
done

echo "==> Done. Staged ${#MAPPINGS[@]} files (owner ${USER_NAME}:${GROUP_NAME})."
echo "    nginx edge certs (CERT_SERVER_*) are separate - see pki/README §3."
