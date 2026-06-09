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
        └──► Traefik :80               ← dynamic routing for teststack runners
                │                         (PathPrefix + StripPrefix rules auto-registered via Podman labels)
                └──► envoy-svc-{id}     ← teststack POD on cactus-net (the pod name is its DNS alias).
                        │                  Traefik strips /envoy-svc-{id} and routes to the runner.
                        │  one pod = one shared network namespace; members talk over localhost:
                        ├── runner          ← sole ingress: the only member bound to 0.0.0.0:8080
                        ├── envoy           ← 127.0.0.1:8000 (the runner proxies device traffic here)
                        ├── envoy-admin     ← 127.0.0.1:8001
                        ├── postgres        ← 127.0.0.1 (listen_addresses=localhost)
                        ├── taskiq-worker   ← notification fan-out (no inbound listener)
                        └── rabbitmq        ← in-pod broker

    cactus-orchestrator ─────────────► Podman socket  ← creates/destroys teststack pods + containers
    (container on cactus-net)            reaches each runner for control at http://envoy-svc-{id}:8080
```

Teststacks are created and destroyed at runtime by `cactus-orchestrator` via the Podman API socket.
No template resources exist on disk — for each teststack the orchestrator creates a single **pod** on
`cactus-net` (the pod name doubles as its DNS alias) and runs the containers from the image map in
`PODMAN_TESTSTACK_IMAGES` inside it. Because all members share the pod's network namespace they reach
each other over `localhost`; only the runner binds `0.0.0.0`, making it the single ingress, while every
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

1. Copy `sample.env` to `cactus.env` in this directory and fill in all values:

```bash
cp sample.env cactus.env
chmod 600 cactus.env   # contains secrets — restrict permissions
$EDITOR cactus.env
```

Key variables to set:
- `ORCHESTRATOR_DATABASE_URL` — asyncpg connection string for the orchestrator postgres.
- `PODMAN_TESTSTACK_IMAGES` — JSON map of CSIP-Aus version → service image tags. The top-level key
  **must be the `CSIPAusVersion` value the orchestrator looks up at spawn — `v1.2` / `v1.3`, with the
  leading `v`** (a bare `1.2` silently fails to match and every spawn errors). Inner keys: `postgres`,
  `pubsub` (RabbitMQ), `teststack_init`, `envoy`, `runner` (the taskiq-worker reuses the `envoy` image,
  so no separate key). Add one entry per supported CSIP-Aus version: **v1.2 uses the `-v12` images
  (envoy 1.x), v1.3 uses the `-v13` images (envoy 2.x)**. The tag prefix is the cactus-deploy release
  tag (`release-podman` → `podman`):
  ```json
  {"v1.2": {"postgres": "postgres:15", "pubsub": "rabbitmq:3",
            "teststack_init": "<registry>/cactus-teststack-init:podman-v12",
            "envoy": "<registry>/cactus-envoy:podman-v12",
            "runner": "<registry>/cactus-runner:podman-v12"},
   "v1.3": {"postgres": "postgres:15", "pubsub": "rabbitmq:3",
            "teststack_init": "<registry>/cactus-teststack-init:podman-v13",
            "envoy": "<registry>/cactus-envoy:podman-v13",
            "runner": "<registry>/cactus-runner:podman-v13"}}
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

Run the setup script once on a fresh host.  It installs Podman, enables the rootful socket, creates the
`cactus-net` network, starts Traefik, creates `/etc/cactus/pki`, and pre-pulls all teststack images. It
does **not** install or configure nginx and does **not** issue TLS certificates — the TLS edge is
hand-managed (see below).

```bash
chmod +x scripts/setup.sh
sudo ./scripts/setup.sh ./cactus.env
```

### nginx / TLS edge (hand-managed)

The device-facing vhost requires AES-128-CCM8, which stock distro nginx cannot provide, so nginx is
**custom-compiled against a CCM-capable OpenSSL and installed out of band** — not by `setup.sh`. After
setup:

1. Install your custom nginx build and confirm the cipher: `openssl ciphers | grep -c CCM8` (must be ≥1).
2. Place the device-facing TLS material at `/etc/nginx/certs/`: `server.fullchain.pem`, `server.key.pem`,
   and `serca.cert.pem` (from §3).
3. Render the config template into your nginx layout. A from-source build has no Debian
   `sites-available`/`sites-enabled` split — place it wherever your build `include`s configs:
   ```bash
   envsubst '${TEST_EXECUTION_FQDN} ${TEST_ORCHESTRATION_FQDN} ${CACTUS_CLIENT_NOTIFICATIONS_MOUNT_POINT}' \
       < nginx/nginx.conf > <your-nginx-conf-path>
   ```
4. Issue the orchestration-domain (UI) certificate. The template references
   `/etc/letsencrypt/live/${TEST_ORCHESTRATION_FQDN}/...`; obtain it however suits the host (e.g.
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
chmod +x scripts/update.sh
sudo ./scripts/update.sh ./cactus.env
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
openssl verify -CAfile /etc/nginx/certs/serca.cert.pem <device-cert.pem>
```
