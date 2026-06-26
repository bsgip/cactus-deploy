# Traefik smoke test

Checks that Traefik discovers an orchestrator-spawned runner and routes to it. This is the bit
`local_testing/README.md` skips (it forwards with `socat` and bypasses Traefik). Run everything as root.

- Use orchestrator commit `149442a` (`git checkout 149442a`). Branch HEAD is a WIP refactor; its "Back to
  curl" healthcheck fails on the curl-less `*-v13` runner image, so the runner never goes healthy and
  Traefik (only routes healthy containers) drops the route.

### Host setup (once)

```bash
sudo podman info --format '{{.Host.NetworkBackend}}'   # expect: netavark
sudo podman network exists cactus-net || sudo podman network create cactus-net
sudo podman network inspect cactus-net --format 'dns={{.DNSEnabled}}'   # expect: dns=true

# userns=auto needs a subuid/subgid range for root, or every spawn fails
grep -q '^root:' /etc/subuid || echo 'root:100000:1048576' | sudo tee -a /etc/subuid
grep -q '^root:' /etc/subgid || echo 'root:100000:1048576' | sudo tee -a /etc/subgid
sudo podman system migrate
```

### 1. Start Traefik

```bash
sudo podman run -d --name traefik --network cactus-net \
    -v /run/podman/podman.sock:/var/run/docker.sock:z \
    -p 127.0.0.1:80:80 -p 127.0.0.1:8090:8080 \
    docker.io/traefik:v3 \
        --api.insecure=true --api.dashboard=true \
        --providers.docker=true \
        --providers.docker.endpoint=unix:///var/run/docker.sock \
        --providers.docker.exposedbydefault=false \
        --providers.docker.network=cactus-net \
        --entrypoints.web.address=:80

curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:80/   # expect: 404 (Traefik up, no route for /)
```

### 2. Spawn a pod

```bash
cd /home/ubuntu/code/cactus-orchestrator
export CSIP_AUS_VERSION=1.3
export PODMAN_TESTSTACK_IMAGES='{"1.3": {"postgres": "docker.io/library/postgres:15", "pubsub": "docker.io/library/rabbitmq:3", "teststack_init": "cactusimageregistry.azurecr.io/cactus-teststack-init:156-v13", "envoy": "cactusimageregistry.azurecr.io/cactus-envoy:156-v13", "runner": "cactusimageregistry.azurecr.io/cactus-runner:156-v13"}}'

sudo -E .venv/bin/python ../cactus-deploy/podman-setup/local_testing/spawn_local.py up
# expect (~20s): "Teststack pod envoy-svc-local ready ..."
```

### 3. Route through Traefik

The pod publishes no host port, so a 200 here means Traefik routed it.

```bash
# route registered? (labels live on the runner — it's the ingress)
curl -s http://127.0.0.1:8090/api/http/routers \
  | python3 -c "import sys,json; [print(r['name'],r.get('status')) for r in json.load(sys.stdin)]"
# expect a line: envoy-svc-local@docker enabled

curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:80/envoy-svc-local/health  # expect: 200
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:80/health                  # expect: 404 (no prefix, no route)
curl -s http://127.0.0.1:80/envoy-svc-local/status                                   # expect: runner status JSON
```

Dashboard: `http://127.0.0.1:8090/dashboard/` → HTTP → Routers.

### 4. Teardown

```bash
cd /home/ubuntu/code/cactus-orchestrator
sudo -E .venv/bin/python ../cactus-deploy/podman-setup/local_testing/spawn_local.py down
sudo podman rm -f traefik
```

### If the route never appears

- Runner stuck `starting` → Traefik won't route. Check `sudo podman inspect envoy-svc-local-runner --format '{{json .State.Health}}'`; `curl: not found` means you're not on `149442a`.
- Route missing entirely → Traefik can't read the socket. Check the `-v ...podman.sock` mount and `sudo podman logs traefik`.
