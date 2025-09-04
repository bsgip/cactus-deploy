#!/bin/bash

usage() {
    echo "create-cert SERCA_ID [CHAIN_ID] [CHAIN_SERIAL] [SERVER_DNS] [SERVER_SERIAL]"
    echo ""
    echo "Creates the specified chain of certificate(s) and keys up to the last specified parameter."
    echo "Will NOT replace existing certs (you will need to manually delete those to force a refresh)"
    echo ""
    echo "SERCA_ID = Mandatory unique id of the root SERCA"
    echo "CHAIN_ID = Optional unique id for the MCA/MICA chain underneath SERCA_ID"
    echo "CHAIN_SERIAL = Optional unique number for the MCA/MICA chain serial number underneath SERCA_ID"
    echo "SERVER_DNS = Optional will create a DNS server certificate underneath the specified MCA/MICA chain"
    echo "SERVER_SERIAL = Optional unique number for the server certificate"
    echo "NOTE: All parameters form parts of a file/folder name"
    exit 1
}

calculate_key_identifier() {
    echo "FOO"
    local key_file=$1
    local pub_file=$2

    echo "BAR"
    # Generate subjectKeyIdentifier from the public key (Method is referenced in 2030.5 - Section 6.11.6)
    # Method requires the least significant 60 bits of the SHA-1 public key 
    openssl ec -in "$key_file" -pubout -outform DER -out "$pub_file" || exit 1

    echo "BAZ"
    local sha1_hash=$(openssl dgst -sha1 -binary $SERCA_KEY_PUB_FILE | xxd -p)

    echo "BAR"
    echo "4${sha1_hash:15}"
    return
}

# Parse parameters
SERCA_ID="$1"
CHAIN_ID="$2"
CHAIN_SERIAL="$3"
SERVER_DNS="$4"
SERVER_SERIAL="$5"
if [[ -z "${SERCA_ID}" ]]; then
    echo "ERROR - No SERCA_ID specified."
    echo ""
    usage
fi

if [[ -n "${CHAIN_ID}" && -z "${CHAIN_SERIAL}" ]]; then
    echo "ERROR - CHAIN_ID was specified but CHAIN_SERIAL was left blank."
    echo ""
    usage
fi

if [[ -n "${SERVER_DNS}" && -z "${SERVER_SERIAL}" ]]; then
    echo "ERROR - SERVER_DNS was specified but SERVER_SERIAL was left blank."
    echo ""
    usage
fi

# 
# SERCA Calculation
#
SERCA_DIR="./$SERCA_ID"
SERCA_KEY_FILE="$SERCA_DIR/key.pem"
SERCA_CERT_FILE="$SERCA_DIR/cert.pem"
SERCA_CSR_FILE="$SERCA_DIR/.csr.pem"
SERCA_PUB_FILE="$SERCA_DIR/.pub.der"



if [ ! -f $SERCA_KEY_FILE ]; then
    echo "Creating SERCA key/cert at '$SERCA_DIR/'"
    mkdir -p "$SERCA_DIR" || exit 1

    # Generate key
    openssl ecparam -name prime256v1 -genkey -noout -out $SERCA_KEY_FILE || exit 1
    chmod 400 $SERCA_KEY_FILE

    # 
    KEY_IDENTIFIER=$(calculate_key_identifier "$SERCA_KEY_FILE" "$SERCA_PUB_FILE")
    echo "KEY_IDENTIFIER $KEY_IDENTIFIER"
    
else
    echo "SERCA key '$SERCA_KEY_FILE' already exists in '$SERCA_DIR/'. Skipping SERCA generation."
fi

