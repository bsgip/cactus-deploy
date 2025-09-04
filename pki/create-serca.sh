#!/bin/bash

SERIAL_FILE="serca-serial"
DATABASE_FILE="serca-db"
CA_CONFIG_FILE="serca-openssl.cnf"
CA_EXT_CONFIG_FILE="serca-ext.cnf"
SERCA_KEY_FILE="serca.key.pem"
SERCA_KEY_PUB_FILE="/tmp/serca.key.pub.der"
SERCA_CERT_FILE="serca.cert.pem"
SERCA_CSR_FILE="serca.csr.pem"

if [ ! -f $SERIAL_FILE ]; then
  echo "Creating serial file at '$SERIAL_FILE'"
  echo "1000" > $SERIAL_FILE
fi

# Generate key
openssl ecparam -name prime256v1 -genkey -noout -out $SERCA_KEY_FILE
chmod 400 $SERCA_KEY_FILE

# Generate subjectKeyIdentifier from the public key (2030.5 6.11.6)
# Method requires the least significant 60 bits of the SHA-1 public key 
openssl ec -in $SERCA_KEY_FILE -pubout -outform DER -out $SERCA_KEY_PUB_FILE
SHA1_HASH=$(openssl dgst -sha1 -binary $SERCA_KEY_PUB_FILE | xxd -p)
KEY_IDENTIFIER="4${SHA1_HASH:15}"

# Generate openssl config file
cat > $CA_CONFIG_FILE <<EOL
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = ./
certs             = ./
crl_dir           = ./
new_certs_dir     = ./
serial            = $SERIAL_FILE
private_key       = $SERCA_KEY_FILE
certificate       = $SERCA_CERT_FILE
database	  = $DATABASE_FILE
x509_extensions   = v3_ca
policy            = policy_serca

[ policy_serca ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = supplied
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional
EOL

cat > $CA_EXT_CONFIG_FILE <<EOL
[ v3_ca ]
basicConstraints       = critical,CA:true
keyUsage               = critical, keyCertSign, cRLSign
subjectKeyIdentifier   = $KEY_IDENTIFIER
EOL

# Generate CSR and sign cert
days_until_9999=$(echo $(( ( $(date -d '9999-12-31' +%s) - $(date +%s) ) / 86400 )))
echo "$days_until_9999 days until 9999-12-31"
openssl req -new -key "$SERCA_KEY_FILE" -out "$SERCA_CSR_FILE" -config "$CA_CONFIG_FILE" -subj '/O=Smart Energy/CN=IEEE 2030.5 Root'
openssl x509 -req -in "$SERCA_CSR_FILE" -extfile "$CA_EXT_CONFIG_FILE" -extensions v3_ca -signkey "$SERCA_KEY_FILE" -out $SERCA_CERT_FILE -days $days_until_9999 


