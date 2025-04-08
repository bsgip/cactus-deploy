#!/bin/bash

# help msg
display_help() {
    echo "Usage: $0 [options]"
    echo
    echo "Create a Kubernetes TLS secret using MicroK8s."
    echo
    echo "Options:"
    echo "  -h, --help          Display this help message and exit."
    echo "  -c, --cert PATH     Path to the TLS certificate file (required)."
    echo "  -k, --key PATH      Path to the TLS private key file (required)."
    echo "  -i, --ingress INGRESS   Name of the ingress resource to update (required)."
    echo "  -n, --namespace NS  Kubernetes namespace (default: 'default')."
    echo
    echo "Example:"
    echo "  $0 --cert /path/to/cert.crt --key /path/to/key.key --namespace some-namespace --ingress some-ingress"
    echo
}

cert_path=""
key_path=""
ingress_name=""
namespace="default"


# Parse options
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help)
            display_help
            exit 0
        ;;
        -c|--cert)
            if [[ -n "$2" ]]; then
                cert_path="$2"
                shift
            else
                echo "Error: --cert requires a path to the certificate file."
                exit 1
            fi
        ;;
        -k|--key)
            if [[ -n "$2" ]]; then
                key_path="$2"
                shift
            else
                echo "Error: --key requires a path to the private key file."
                exit 1
            fi
        ;;
        -i|--ingress)
            ingress_name="$2"
            shift
        ;;
        -n|--namespace)
            if [[ -n "$2" ]]; then
                namespace="$2"
                shift
            else
                echo "Error: --namespace requires a namespace name."
                exit 1
            fi
        ;;
        *)
            echo "Unknown option: $1"
            display_help
            exit 1
        ;;
    esac
    shift
done

# Validate inputs & check they exist
if [[ -z "$cert_path" || -z "$key_path" || -z "$ingress_name" ]]; then
    echo "Error: Both --cert and --key are required."
    display_help
    exit 1
fi

if [[ ! -f "$cert_path" ]]; then
    echo "Error: Certificate file '$cert_path' does not exist."
    exit 1
fi

if [[ ! -f "$key_path" ]]; then
    echo "Error: Private key file '$key_path' does not exist."
    exit 1
fi

# Extract all SANs from cert
san_list=($(openssl x509 -in "$cert_path" -noout -text \
        | awk '/Subject Alternative Name/ {getline; print}' \
| sed -E 's/DNS://g; s/, /\n/g'))

if [[ ${#san_list[@]} -eq 0 ]]; then
    # Fall back to CN if no SANs found
    domain=$(openssl x509 -in "$cert_path" -noout -subject | sed -n 's/.*CN *= *\([^ /]*\).*/\1/p')
    if [[ -z "$domain" ]]; then
        echo "Error: Could not determine any domain from the certificate."
        exit 1
    fi
    echo "No SANs found. Using CN: $domain"
else
    echo "Available domains found in certificate, pick one:"
    select domain in "${san_list[@]}"; do
        if [[ -n "$domain" ]]; then
            echo "You selected: $domain"
            break
        else
            echo "Invalid selection. Try again."
        fi
    done
fi

read -p "Proceed certificate install for domain '$domain'? (y/N): " confirm
confirm=${confirm,,} # lowercase

if [[ "$confirm" != "y" ]]; then
    echo "Operation aborted by user."
    exit 1
fi

# Create the Kubernetes TLS secret
secret_name="tls-server-${domain//./-}" # format for secret names
echo "Creating TLS secret ($secret_name) in namespace '$namespace'..."

if microk8s kubectl get secret "$secret_name" -n "$namespace" &>/dev/null; then
    echo "Secret '$secret_name' already exists. Updating it..."
    microk8s kubectl delete secret "$secret_name" -n "$namespace"
fi

echo "Creating TLS secret ($secret_name) in namespace '$namespace'..."
microk8s kubectl create secret tls "$secret_name" --namespace "$namespace" --cert "$cert_path" --key "$key_path"


if [[ $? -eq 0 ]]; then
    echo "TLS secret '$secret_name' created successfully in namespace '$namespace'."
else
    echo "Error: Failed to create TLS secret."
    exit 1
fi


# Try extract existing TLS hosts from the Ingress definition
existing_tls=$(microk8s kubectl get ingress "$ingress_name" -n "$namespace" -o json | jq -r '.spec.tls // ""')

if echo "$existing_tls" | grep -q "\"$domain\""; then
    echo "Domain '$domain' already exists in Ingress TLS. Only needed to update secret."
else
    echo "Adding new TLS entry for '$domain' with host routing..."
    
    microk8s kubectl patch ingress "$ingress_name" -n "$namespace" --type='json' -p "[
        {
    \"op\": \"add\",
    \"path\": \"/spec/rules/0/host\",
    \"value\": \"$domain\"
        }
    ]"
    
    if [[ -z "$existing_tls" || "$existing_tls" == "null" ]]; then
        # Initialize tls array if missing
        microk8s kubectl patch ingress "$ingress_name" -n "$namespace" --type='json' -p "[
          {
            \"op\": \"add\",
            \"path\": \"/spec/tls\",
            \"value\": [{
              \"hosts\": [\"$domain\"],
              \"secretName\": \"$secret_name\"
            }]
          }
        ]"
    else
        # Append new entry
        microk8s kubectl patch ingress "$ingress_name" -n "$namespace" --type='json' -p "[
          {
            \"op\": \"add\",
            \"path\": \"/spec/tls/-\",
            \"value\": {
              \"hosts\": [\"$domain\"],
              \"secretName\": \"$secret_name\"
            }
          }
        ]"
    fi
fi

if [[ $? -eq 0 ]]; then
    echo "Ingress resource '$ingress_name' updated successfully."
else
    echo "Error: Failed to update Ingress resource."
    exit 1
fi