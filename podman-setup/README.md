This README describes the end-to-end setup of the Cactus orchestration platform using rootful Podman.

NOTE: All commands should be run as root unless specified otherwise.

## Architecture overview

```
DER clients (TLS 1.2 / AES-128-CCM8)
        │
        ▼
    nginx :443                          ← TLS termination; CCM8 cipher; mTLS verification
        │
        ├──► cactus-ui :5000            ← Flask UI (proxied directly from nginx)
        │
        └──► Traefik :80               ← dynamic routing for teststack envoy instances
                │                         (path-prefix rules auto-registered via Podman labels)
                └──► envoy-svc-{id}    ← per-test Podman pod on cactus-net
                        ├── envoy
                        ├── cactus-runner
                        ├── postgres
                        ├── taskiq-worker
                        └── pubsub (redis)

    cactus-orchestrator ─────────────► Podman socket  ← creates/destroys teststack pods
    (container on cactus-net)
```

Teststack pods are created and destroyed at runtime by `cactus-orchestrator` via the Podman API socket.
No template resources exist on disk — the orchestrator builds each pod from the image map in
`PODMAN_TESTSTACK_IMAGES`.

---

## (1) Prerequisites

Ubuntu 24.04.  The setup script handles most of the installation, but verify:

- Static IP assigned and DNS records created for both `TEST_EXECUTION_FQDN` and `TEST_ORCHESTRATION_FQDN`.
- External PostgreSQL instance reachable from this host (for the orchestrator database).
- Container registry credentials available if using a private registry.

**AES-128-CCM8 cipher requirement:**  IEEE 2030.5 mandates this cipher for DER device connections.
Standard nginx packages do not include it.  Verify support before proceeding:

```bash
openssl ciphers | tr ':' '\n' | grep CCM8
# If empty, install a CCM-capable OpenSSL build and rebuild nginx against it.
```

---

## (2) Prepare configuration

1. Copy `sample.env` to `cactus.env` in this directory and fill in all values:

```bash
cp sample.env cactus.env
chmod 600 cactus.env   # contains secrets — restrict permissions
$EDITOR cactus.env
```

Key variables to set:
- `ORCHESTRATOR_DATABASE_URL` — asyncpg connection string for the orchestrator postgres.
- `PODMAN_TESTSTACK_IMAGES` — JSON map of CSIP-Aus version → service image tags.
  Example for version 1.3:
  ```json
  {"1.3": {"postgres": "postgres:15", "pubsub": "redis:7",
           "envoy": "<registry>/cactus-envoy:<tag>",
           "taskiq-worker": "<registry>/cactus-envoy:<tag>",
           "runner": "<registry>/cactus-runner:<tag>"}}
  ```
- `CERT_*_PATH` — host paths to PKI artefacts (generated in step 3).
- `AUTH0_*` / `APP_SECRET_KEY` — OAuth2 credentials for cactus-ui.
- `JWTAUTH_*` — JWT validation settings for cactus-orchestrator.

---

## (3) PKI creation

The `../pki/create-cert.sh` script generates the full IEEE 2030.5 certificate chain.

```bash
cd ../pki

# Server signing chain (SAN must match TEST_EXECUTION_FQDN)
./create-cert.sh cactus 1 server-chain 1 envoy.example.com 1

# Cactus client signing chain (used to sign DER client certificates)
./create-cert.sh cactus 1 cactus-chain 2
```

This produces:
- `cactus/`         — SERCA root CA certificate
- `server-chain/`   — MCA/MICA for signing the utility server TLS certificate
- `cactus-chain/`   — MCA/MICA for signing DER client certificates
- `envoy.example.com/` — signed server certificate + full chain

Copy the artefacts to the paths configured in `cactus.env`:

```bash
mkdir -p /etc/cactus/pki
chmod 700 /etc/cactus/pki
cp cactus/serca.cert.pem                          /etc/cactus/pki/serca.cert.pem
cp cactus-chain/mca.cert.pem                      /etc/cactus/pki/cactus-chain/mca.cert.pem
cp cactus-chain/mica.cert.pem                     /etc/cactus/pki/cactus-chain/mica.cert.pem
cp cactus-chain/mica.key.pem                      /etc/cactus/pki/cactus-chain/mica.key.pem

# nginx server certificate
mkdir -p /etc/nginx/certs
cp envoy.example.com/envoy.example.com.fullchain.pem  /etc/nginx/certs/server.fullchain.pem
cp envoy.example.com/envoy.example.com.key.pem        /etc/nginx/certs/server.key.pem
cp cactus/serca.cert.pem                              /etc/nginx/certs/serca.cert.pem
chmod 600 /etc/nginx/certs/server.key.pem
```

---

## (4) Infrastructure setup

Run the setup script once on a fresh host.  It installs Podman, creates the `cactus-net` network,
starts Traefik, installs nginx, and pre-pulls all teststack images.

```bash
chmod +x scripts/setup.sh
sudo ./scripts/setup.sh ./cactus.env
```

After setup, obtain a Let's Encrypt certificate for the orchestration domain:

```bash
sudo certbot --nginx -d cactus.example.com
```

Then reload nginx:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

---

## (5) Database setup

The orchestrator requires an external PostgreSQL instance.

1. Create the database and user:
   ```sql
   CREATE USER cactususer WITH PASSWORD 'your-password';
   CREATE DATABASE cactusorchestrator OWNER cactususer;
   ```
2. Configure `pg_hba.conf` to allow the host's IP.
3. Run Alembic migrations from the `cactus-orchestrator` repository:
   ```bash
   cd /path/to/cactus-orchestrator
   ORCHESTRATOR_DATABASE_URL="postgresql+asyncpg://..." uv run alembic upgrade head
   ```

---

## (6) Deploy application containers

```bash
chmod +x scripts/update.sh
sudo ./scripts/update.sh ./cactus.env
```

This pulls the latest images for `cactus-orchestrator`, `cactus-ui`, and `cactus-client-notifications`,
then recreates those containers.  Teststack containers are not touched by this script — the
orchestrator manages them at runtime.

Verify all three containers are running:

```bash
podman ps --filter name=cactus
```

---

## (7) Updating images

Re-run the update script whenever images are rebuilt:

```bash
sudo ./scripts/update.sh ./cactus.env
```

To update the teststack images referenced in `PODMAN_TESTSTACK_IMAGES`: edit `cactus.env`, then
re-run `update.sh`.  The orchestrator reads `PODMAN_TESTSTACK_IMAGES` at startup; restart it to
pick up changes:

```bash
podman restart cactus-orchestrator
```

---

## (8) Smoke test

After deployment, verify end-to-end routing:

```bash
# 1. Traefik is reachable from the host
curl -s http://127.0.0.1:80/ | head -5

# 2. Orchestrator health endpoint
curl -s http://127.0.0.1:8000/health

# 3. UI is serving
curl -skI https://cactus.example.com/ | head -5

# 4. Spawn a minimal test pod and check Traefik picks it up
podman pod create --name envoy-svc-smoke --network cactus-net
podman run -d --pod envoy-svc-smoke \
    --label "traefik.enable=true" \
    --label "traefik.http.routers.envoy-svc-smoke.rule=PathPrefix(\`/envoy-svc-smoke\`)" \
    --label "traefik.http.routers.envoy-svc-smoke.entrypoints=web" \
    --label "traefik.http.services.envoy-svc-smoke.loadbalancer.server.port=80" \
    nginx:alpine
curl -s http://127.0.0.1:80/envoy-svc-smoke/   # should reach nginx:alpine
podman pod rm --force envoy-svc-smoke
```

---

## Troubleshooting

**Orchestrator can't reach Podman socket:**
```bash
ls -la /run/podman/podman.sock
podman exec cactus-orchestrator ls -la /run/podman/podman.sock
```

**Traefik not routing a teststack:**
```bash
# Check Traefik API (dashboard on port 8080 if --api.insecure=true was added to setup)
podman logs traefik

# Check container labels are present
podman inspect envoy-svc-<id>-envoy | jq '.[0].Config.Labels'
```

**Certificate errors on test-execution domain:**
```bash
nginx -T | grep ssl_client_certificate
openssl verify -CAfile /etc/nginx/certs/serca.cert.pem <device-cert.pem>
```
