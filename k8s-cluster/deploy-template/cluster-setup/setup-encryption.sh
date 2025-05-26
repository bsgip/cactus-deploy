#!/bin/bash

echo "This script will create or rotate the encryption key used for the secret store at-rest-encryption."
echo "User can either provide a key or it will be created."
echo
echo "NOTES:"
echo "- This script needs sudo privileges"
echo "- It involves restarting microk8s"
echo

set -e # Exit on error

ENCRYPTION_CONFIG_PATH="/var/snap/microk8s/current/certs/encryption-config.yaml"

# Check if encryption config exists
if [[ ! -f "$ENCRYPTION_CONFIG_PATH" ]]; then
    echo "No existing encryption config found. Creating a new one..."
    sudo touch "$ENCRYPTION_CONFIG_PATH"
    sudo chmod 600 "$ENCRYPTION_CONFIG_PATH"
    CONFIG_EXISTS=false
else
    echo "Encryption config already exists. Rotating keys.."
    CONFIG_EXISTS=true
fi

# Prompt for a new encryption key (or auto-generate)
read -s -p "Enter base64 encoded encryption key or leave blank to auto-generate: " USER_KEY
echo
if [[ -z "$NEW_KEY" ]]; then
    NEW_KEY=$(openssl rand -base64 32)
    echo "Generated new encryption key."
    echo $NEW_KEY
fi

# Extract current encryption key name and make backup existing of config
if [[ "$CONFIG_EXISTS" == true ]]; then
    OLD_KEY_NAME=$(sudo grep -m1 "name:" $ENCRYPTION_CONFIG_PATH | awk '{print $2}')
    sudo cp $ENCRYPTION_CONFIG_PATH "$ENCRYPTION_CONFIG_PATH.bak"
else
    OLD_KEY_NAME=""
fi

# Update encryption config, include old key if rotating.
# We keep the old key so existing secrets for decryption on restart.
# New secrets will then be encrypted with the new key, since encryption keys
# are selected based on order in this config (first key is used).
# Once all secrets are re-encrypted with the new key, the old key is removed.
NEW_KEY_NAME="kss-key-$(date +%s)"
cat <<EOF | sudo tee $ENCRYPTION_CONFIG_PATH >/dev/null
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: ${NEW_KEY_NAME}
              secret: ${NEW_KEY}
      - identity: {}
EOF

if [[ -n "$OLD_KEY_NAME" ]]; then
    cat <<EOF | sudo tee -a $ENCRYPTION_CONFIG_PATH >/dev/null
            - name: ${OLD_KEY_NAME}
              secret: ${OLD_KEY_SECRET}
EOF
fi

cat <<EOF | sudo tee -a $ENCRYPTION_CONFIG_PATH >/dev/null
      - identity: {}
EOF

echo "New key added: ${NEW_KEY_NAME}"

# Apply changes
echo "Restarting MicroK8s..."
sudo microk8s stop
sudo microk8s start

if [[ -n "$OLD_KEY_NAME" ]]; then
    # This should re-encrypt existing secrets with the new key
    echo "Re-encrypting all Kubernetes secrets with new key..."
    microk8s kubectl get secrets --all-namespaces -o json | kubectl replace -f -

    # Remove old key from encryption config
    echo "Removing old encryption key: ${OLD_KEY_NAME}"
    cat <<EOF | sudo tee $ENCRYPTION_CONFIG_PATH >/dev/null
    apiVersion: apiserver.config.k8s.io/v1
    kind: EncryptionConfiguration
    resources:
    - resources:
        - secrets
        providers:
        - aescbc:
            keys:
                - name: ${NEW_KEY_NAME}
                secret: ${NEW_KEY}
        - identity: {}
EOF

    # Restart again
    sudo microk8s stop
    sudo microk8s start
fi

echo "Done!"
