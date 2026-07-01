This README describes the end-to-end setup of the Cactus orchestration platform using rootful Podman.

NOTE: All commands should be run as root unless specified otherwise.

## Architecture overview

### Web UI
```
Web UI Clients (eg https://cactus.host/)
│
└──► nginx :443                        ← Standard TLS Termination 
      │                                  (eg LetsEncrypt, standard ciphers)
      |
      ├──► cactus-ui :5000             ← Web UI
      |     │
      |     |
      |     └──► cactus-orchestrator :8000   ← Web Service API
      |           │                            (access to podman network 'cactus-net')
      |           |
      |           └──► Podman socket   ← Creating Pods / accessing running pods 
      |
      └──► cactus-client-notifications :5002 ← Seperate service to support cactus-client
```

### DER Clients

```
DER clients (TLS 1.2 / AES-128-CCM8) via subdomain (eg https://run-123.cactus.host/)
│        
│        
└──► nginx :443                  ← TLS termination; CCM8 cipher; mTLS verification
        │
        └──► Traefik :5001       ← dynamic routing for test pods
               │                   (Requests will be downstream of a constant href_prefix eg /envoy)
               |
               └──► run-{id}     ← teststack POD on cactus-net (the pod name is its DNS alias).
                        │          Traefik strips /envoy and routes to the runner.
                        |
                        │  one pod = one shared network namespace; members talk over localhost:
                        ├── runner          ← sole ingress: the only member bound to 0.0.0.0:8080
                        ├── envoy           ← 127.0.0.1:8000 (the runner proxies device traffic here)
                        ├── envoy-admin     ← 127.0.0.1:8001
                        └── postgres        ← 127.0.0.1 (listen_addresses=localhost)
```

Teststacks are created and destroyed at runtime by `cactus-orchestrator` via the Podman API socket.
No template resources exist on disk — for each teststack the orchestrator creates a single **pod** on
`cactus-net` (the pod name doubles as its DNS alias) and runs the containers from the images in 
orchestrator. Because all members share the pod's network namespace they reach each other over `localhost`; 
only the runner binds `0.0.0.0`, making it the single ingress, while every
other service binds `127.0.0.1` and so is unreachable from other teststacks on `cactus-net`.

---

## (1) Prerequisites

Ubuntu 24.04.  `setup.sh` installs Podman and Traefik and pre-pulls images, but you must provide:

- Static IP assigned and DNS records created for both `TEST_EXECUTION_FQDN` and `TEST_ORCHESTRATION_FQDN`.
- External PostgreSQL instance reachable from this host (for the orchestrator database).
- Container registry credentials available if using a private registry.
- A custom-compiled, CCM8-capable nginx (see the cipher note below) — `setup.sh` does **not** install or
  configure nginx; the TLS edge is hand-managed (see §4).

**AES-128-CCM8 cipher requirement:**  IEEE 2030.5 mandates this cipher for DER device connections, and
standard distro nginx packages do not include it — which is why nginx is custom-compiled against a
CCM-capable OpenSSL and installed out of band rather than by `setup.sh`.  Verify support on whatever
nginx build you install:

```bash
openssl ciphers | tr ':' '\n' | grep CCM8
# If empty, that OpenSSL build lacks CCM8 — rebuild nginx against a CCM-capable OpenSSL.
```

---

## (2) Prepare configuration

1. Copy `sample.cactus.env` to `cactus.env` in this directory and fill in all values:

```bash
cp sample.cactus.env cactus.env
chmod 600 cactus.env   # contains secrets — restrict permissions
$EDITOR cactus.env
```

Key variables to set:
- `ORCHESTRATOR_DATABASE_URL` — asyncpg connection string for the orchestrator postgres.
- `CACTUS_IMAGE__*` — See cactus-orchestrator README.md for more info:
```
CACTUS_IMAGE__V1_2__CSIP_AUS_VERSION = "v1.2"
CACTUS_IMAGE__V1_2__POSTGRES = "docker.io/library/postgres:15"
CACTUS_IMAGE__V1_2__RABBITMQ = "docker.io/library/rabbitmq:3"
CACTUS_IMAGE__V1_2__INIT = "cactusimageregistry.azurecr.io/cactus-teststack-init:158-v12"
CACTUS_IMAGE__V1_2__ENVOY = "cactusimageregistry.azurecr.io/cactus-envoy:158-v12"
CACTUS_IMAGE__V1_2__RUNNER = "cactusimageregistry.azurecr.io/cactus-runner:158-v12"

CACTUS_IMAGE__V1_3__CSIP_AUS_VERSION = "v1.3"
CACTUS_IMAGE__V1_3__POSTGRES = "docker.io/library/postgres:15"
CACTUS_IMAGE__V1_3__RABBITMQ = "docker.io/library/rabbitmq:3"
CACTUS_IMAGE__V1_3__INIT = "cactusimageregistry.azurecr.io/cactus-teststack-init:158-v13"
CACTUS_IMAGE__V1_3__ENVOY = "cactusimageregistry.azurecr.io/cactus-envoy:158-v13"
CACTUS_IMAGE__V1_3__RUNNER = "cactusimageregistry.azurecr.io/cactus-runner:158-v13"
```
- `CERT_*_PATH` — host paths to PKI artefacts (generated in step 3).
- `AUTH0_*` / `APP_SECRET_KEY` — OAuth2 credentials for cactus-ui.
- `JWTAUTH_*` — JWT validation settings for cactus-orchestrator.

---

## (3) PKI creation and staging

The full certificate hierarchy (one SERCA root + the device, aggregator, and DNSP-envoy chains) and how
to stage the orchestrator's subset are documented in **`../pki/README.md`** — the single source of truth.
In short:

```bash
cd ../pki
# 1. Generate the chains (pki/README §1) — do this on an offline/scratch host: it mints the CA private
#    keys, which must never live on the orchestrator host.
# 2. Stage only the least-privilege subset into the cactus.env CERT_* paths (cactus:cactus, right modes):
sudo ./stage-certs.sh . ../server/cactus.env
```

`stage-certs.sh` copies the SERCA public cert, the MICA + aggregator-ICA signing keys/certs, and the
envoy EE fullchain + key — never the SERCA/MCA/PCA/DNSP-ICA private keys — and populates every
orchestrator `CERT_*_PATH` in `cactus.env`.

---

## (4) Infrastructure setup

Run the setup script once on a fresh host.  It installs Podman, enables the rootful socket, creates the
`cactus-net` network, starts Traefik, creates `/etc/cactus/pki`, and pre-pulls all teststack images. It
does **not** install or configure nginx and does **not** issue TLS certificates — the TLS edge is
hand-managed (see below).

```bash
sudo ./setup.sh ./cactus.env
```

### nginx / TLS edge (hand-managed)

The device-facing vhost requires AES-128-CCM8, which stock distro nginx cannot provide, so nginx is
**custom-compiled against a CCM-capable OpenSSL and installed out of band** — not by `setup.sh`. After
setup:

1. Install your custom nginx build and confirm the cipher: `openssl ciphers | grep -c CCM8` (must be ≥1).
2. Place the device-facing TLS material at the `cactus.env` paths the config renders:
   `CERT_ENVOY_EE_FULLCHAIN_PATH`, `CERT_ENVOY_EE_KEY_PATH`, and the `CERT_SERCA_PATH` trust anchor.
3. Render the config template into your nginx layout. A from-source build has no Debian
   `sites-available`/`sites-enabled` split — place it wherever your build `include`s configs:
   ```bash
   ./nginx-config.sh > <your-nginx-conf-path>
   ```
4. Issue the orchestration-domain (UI) certificate. The template references
   `/etc/letsencrypt/live/${CACTUS_FQDN}/...`; obtain it however suits the host (e.g.
   `certbot certonly --webroot` or a DNS-01 challenge — the `--nginx` plugin is not used, as it assumes a
   distro nginx layout). Adjust the paths in the rendered config if you issue certs elsewhere.
5. Validate and reload: `nginx -t && systemctl reload nginx` (or your build's equivalent).

### Enable userns for teststack pods

The orchestrator spawns every teststack pod with `userns=auto`, which requires the rootful user (`root`)
to have a subordinate UID/GID range — without it **every spawn fails**. `setup.sh` does not set this; add
it once on the host:

```bash
grep -q '^root:' /etc/subuid || echo 'root:100000:1048576' | sudo tee -a /etc/subuid
grep -q '^root:' /etc/subgid || echo 'root:100000:1048576' | sudo tee -a /etc/subgid
sudo podman system migrate
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
sudo ./update.sh ./cactus.env
```

This pulls the latest
`cactus-orchestrator`, `cactus-ui`, and `cactus-client-notifications` images and recreates those
containers, and **pre-pulls the teststack images** named in `PODMAN_TESTSTACK_IMAGES`. The teststack
containers themselves are not started here — the orchestrator creates them at runtime, and will lazily
pull any teststack image still missing on first spawn (so the pre-pull is just there to keep that first
spawn warm).

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

To update the teststack images referenced in `PODMAN_TESTSTACK_IMAGES`: edit `cactus.env` (point a
version at its new release tag), then re-run `update.sh`. The orchestrator reads
`PODMAN_TESTSTACK_IMAGES` from its environment at startup, and `update.sh` **recreates** the
orchestrator container, so the new map is picked up automatically — no separate restart needed.

> Use `update.sh`, not `podman restart cactus-orchestrator`. A plain restart reuses the container's
> existing environment and will **not** pick up an edited `PODMAN_TESTSTACK_IMAGES`; only recreating
> the container (what `update.sh` does) reloads it.

We publish a **fresh image tag per release**, so updating a version always points it at a tag the host
does not have yet — `update.sh` pre-pulls it, and the orchestrator would lazily pull it anyway. Tags
are never overwritten in place, so there is no stale-image risk.

### Pruning old teststack images

Because every release uses a new tag, superseded teststack images accumulate on the host and are never
removed automatically. Periodically reclaim disk once no teststack is running an old tag:

```bash
# Remove dangling/untagged layers (always safe)
podman image prune -f

# Then remove specific superseded teststack tags no longer referenced in PODMAN_TESTSTACK_IMAGES, e.g.
podman rmi cactusimageregistry.azurecr.io/cactus-runner:podman-v13   # an old release tag
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

# 4. Spawn a minimal teststack-shaped POD and check Traefik picks up the runner's labels.
#    Mirrors the real wiring: a pod on cactus-net, the ingress container bound to 0.0.0.0 with
#    PathPrefix + StripPrefix labels (the prefix is stripped before the ingress, which serves at root).
podman pod create --name envoy-svc-smoke --network cactus-net
podman run -d --name envoy-svc-smoke-runner --pod envoy-svc-smoke \
    --label traefik.enable=true \
    --label traefik.docker.network=cactus-net \
    --label 'traefik.http.routers.envoy-svc-smoke.rule=PathPrefix(`/envoy-svc-smoke`)' \
    --label traefik.http.routers.envoy-svc-smoke.entrypoints=web \
    --label traefik.http.routers.envoy-svc-smoke.middlewares=envoy-svc-smoke-strip \
    --label traefik.http.middlewares.envoy-svc-smoke-strip.stripprefix.prefixes=/envoy-svc-smoke \
    --label traefik.http.services.envoy-svc-smoke.loadbalancer.server.port=80 \
    docker.io/library/nginx:alpine
curl -s http://127.0.0.1:80/envoy-svc-smoke/   # should reach nginx:alpine at root (prefix stripped)
podman pod rm -f envoy-svc-smoke
```

(Or simpler: spawn a real teststack via the UI and assert the route appears.)

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

# Labels live on the runner (it is the ingress) — confirm they are present
podman inspect envoy-svc-<id>-runner | jq '.[0].Config.Labels'

# Confirm the pod is attached to cactus-net (the pod name is its DNS alias)
podman pod inspect envoy-svc-<id> | jq '.InfraConfig.Networks'

# The runner must be the only pod member bound to 0.0.0.0; internals bind 127.0.0.1
podman exec envoy-svc-<id>-runner sh -c 'ss -ltn 2>/dev/null || netstat -ltn'
```

**Certificate errors on test-execution domain:**
```bash
nginx -T | grep ssl_client_certificate
openssl verify -CAfile "$CERT_SERCA_PATH" <device-cert.pem>   # e.g. /etc/cactus/pki/serca.cert.pem
```
