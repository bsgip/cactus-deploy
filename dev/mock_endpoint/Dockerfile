# syntax=docker/dockerfile:1

########################################
# Stage 1: derive certs/key/config from
# the source material dropped next to
# this Dockerfile at build time.
########################################
FROM alpine:3.20 AS certbuilder

RUN apk add --no-cache openssl

WORKDIR /build

# Source material (expected alongside the Dockerfile):
#   serca.pem                     - root CA of both chains
#   utility-server-fullchain.pem  - leaf + intermediates for the service's client cert chain
#   certificate.pfx               - cert+key this endpoint will present (no password)
#   fullchain.pem                 - full chain (leaf..serca) matching certificate.pfx
COPY serca.pem utility-server-fullchain.pem certificate.pfx fullchain.pem ./

# --- Server identity: pull the private key out of the pfx (no import password) ---
# `openssl pkey` normalises whatever key type is inside (RSA/EC) into a clean PEM,
# stripping the "Bag Attributes" noise that `pkcs12 -nocerts` prints alongside it.
RUN openssl pkcs12 -in certificate.pfx -nocerts -nodes -passin pass: \
      | openssl pkey -out server.key

# The full chain to present to clients is already fullchain.pem (leaf..serca),
# just carry it forward under a predictable name.
RUN cp fullchain.pem server.crt

# --- Client trust store: verify the OTHER side's cert against this bundle ---
# utility-server-fullchain.pem = leaf (the far side's own cert) + its intermediates.
# nginx's ssl_client_certificate wants the *trusted CAs*, not the leaf, so strip
# the first PEM block (the leaf) and keep the intermediate(s), then append the root.
RUN awk '/BEGIN CERTIFICATE/{n++} {print > ("chain-" n ".pem")}' utility-server-fullchain.pem \
      && rm -f chain-1.pem \
      && cat chain-*.pem serca.pem > client-ca.pem

# --- Extract the DNS SAN from the pfx's leaf cert and drop it into the nginx conf ---
RUN openssl pkcs12 -in certificate.pfx -clcerts -nokeys -passin pass: > leaf.crt \
      && SERVER_NAME=$(openssl x509 -in leaf.crt -noout -ext subjectAltName \
           | grep -oE 'DNS:[^,]*' | sed 's/DNS://' | tr -d ' ' | paste -sd ' ') \
      && test -n "$SERVER_NAME" \
      && echo "Resolved server_name: $SERVER_NAME"

COPY nginx.conf.template ./
RUN SERVER_NAME=$(openssl x509 -in leaf.crt -noout -ext subjectAltName \
        | grep -oE 'DNS:[^,]*' | sed 's/DNS://' | tr -d ' ' | paste -sd ' ') \
    && sed "s/__SERVER_NAME__/${SERVER_NAME}/" nginx.conf.template > default.conf

########################################
# Stage 2: minimal runtime image
########################################
FROM docker.io/library/nginx:alpine

COPY --from=certbuilder /build/default.conf   /etc/nginx/conf.d/default.conf
COPY --from=certbuilder /build/server.crt     /etc/nginx/certs/server.crt
COPY --from=certbuilder /build/server.key     /etc/nginx/certs/server.key
COPY --from=certbuilder /build/client-ca.pem  /etc/nginx/certs/client-ca.pem

EXPOSE 8443

CMD ["nginx", "-g", "daemon off;"]