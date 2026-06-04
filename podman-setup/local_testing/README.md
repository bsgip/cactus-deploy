# Local testing — teststack smoke test

> **This entire directory is for local development only.**
> In production the orchestrator manages teststack pods directly via the Podman API.
> None of this is used in a real deployment.

Spins up a **real teststack pod** locally via `spawn_local.py`, which calls the orchestrator's
`PodmanTeststackManager` directly — so you exercise the exact wiring used in production (one pod on
`cactus-net`, the runner as the sole ingress, internals on `localhost`) with no auth, database, or UI to
stand up, and nothing to drift out of sync. You then drive the runner API by hand to simulate DER device
requests (curl, Postman, etc.).

The pod has the same shape the orchestrator builds: `runner` (the only `0.0.0.0` ingress), `envoy` and
`envoy-admin` on `127.0.0.1`, plus `postgres`, `rabbitmq`, and `taskiq-worker`. Like production, the pod
publishes **no host port** — the Start section forwards the runner to `localhost:18080` so the examples
below work unchanged.

---

## Prerequisites

Fresh Ubuntu 24.04 box. Run everything **as root** — `spawn_local.py` talks to the rootful Podman
socket, which is root-owned.

```bash
# 1. Podman + the rootful API socket spawn_local.py connects to.
apt install -y podman
systemctl enable --now podman.socket
ls -l /run/podman/podman.sock                 # must exist before continuing

# 2. The shared network the pod joins.
podman network create cactus-net

# 3. The orchestrator package — spawn_local.py imports cactus_orchestrator and drives its real
#    PodmanTeststackManager, so it must run from that repo's venv. Use the podman branch:
git clone https://github.com/bsgip/cactus-orchestrator.git
cd cactus-orchestrator
git checkout podman-pod-consolidation
uv sync                                       # creates .venv with cactus_orchestrator + podman deps
```

> **Podman version:** v4.x (the Ubuntu 24.04 default) and v5.x both work — `manager.py` carries a
> v4/v5 healthcheck shim. Podman v3 or older will not.

Teststack images (`cactusimageregistry.azurecr.io`, public — no login) are **pulled automatically by
`spawn_local.py`** on first `up`. The orchestrator itself never pulls (it fails fast on a missing
image); in a real deployment they are pre-pulled by `setup.sh`.

---

## Start

```bash
# 1. Spawn the pod (the same wiring the orchestrator builds in production).
#    Run from inside the cactus-orchestrator clone so `uv run` uses its venv; point at this script
#    in the cactus-deploy checkout. First run pulls the teststack images (slow); later runs reuse them.
#    Set CSIP_AUS_VERSION=1.2 for the envoy-1.x (-v12) stack; default is 1.3 (-v13).
cd /path/to/cactus-orchestrator
uv run python /path/to/cactus-deploy/podman-setup/local_testing/spawn_local.py up
#    (override images/socket/version via sample.env — see that file)

# 2. The pod publishes no host port (matches prod). Forward the runner to localhost:18080 so the
#    examples below work. The runner binds 0.0.0.0, so a socat container on cactus-net can reach it:
podman run -d --name envoy-svc-local-fwd --network cactus-net -p 18080:18080 \
    docker.io/alpine/socat TCP-LISTEN:18080,fork,reuseaddr TCP:envoy-svc-local:8080

# 3. Wait for the runner to answer (~25–30 s for the stack to boot):
curl http://localhost:18080/health
```

> Envoy is bound to `127.0.0.1` inside the pod (isolation), so it is **not** reachable via the cactus-net
> forwarder. To poke envoy directly for debugging, exec into the pod, e.g.
> `podman exec envoy-svc-local-envoy curl -s "http://localhost:8000/status/version?check_data=false"`.

---

## Client certificate setup

Every request proxied through the runner to envoy must include a `ssl-client-cert`
header containing the URL-encoded PEM of the device/aggregator certificate. The runner
derives an LFDI from the cert in `RunRequest.run_group.test_certificates` and registers
it in envoy during `/initialise` — the same cert in the header is how envoy identifies
each device request.

`test-client.cert.pem` / `test-client.key.pem` in this directory are a self-signed
certificate pair for local use. The key has no password. `example-playlist.json` already
references this cert.

**LFDI:** `504CBE1BB6C3E36EC5C0080F8F785D2585621D69`

Load `test-client.cert.pem` and `test-client.key.pem` into your HTTP client as a client
certificate for `localhost`. Then add a custom request header to all proxied requests:

```
ssl-client-cert: <url-encoded PEM>
```

Get the URL-encoded value:

```bash
python3 -c "import urllib.parse; print(urllib.parse.quote(open('test-client.cert.pem').read()))"
```

> **Note:** some tests (e.g. ALL-01) hardcode a spec-defined aggregator LFDI in their
> preconditions rather than deriving it from the cert. Envoy returns 500 for those
> proxied requests because the cert won't match. The runner marks steps complete on
> request arrival regardless of the response code — tests whose only criteria is
> `all-steps-complete` pass anyway. Tests with stricter criteria (e.g.
> `der-capability-contents`) need envoy to actually process the request successfully,
> which requires the cert header to match.

---

## Runner API

All endpoints at `http://localhost:18080` (the forwarded runner).

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/health` | Liveness / version |
| `GET` | `/status` | Current test state and criteria |
| `POST` | `/initialise` | Load a test or playlist, apply preconditions |
| `POST` | `/start` | Enable the first test step |
| `POST` | `/finalize` | End the test; returns ZIP with PDF report + logs |
| `*` | `/<anything else>` | Proxied to envoy — simulate the DER device here |

---

## Example: ALL-01 + ALL-05 playlist

`example-playlist.json` contains a two-test playlist using `test-client.cert.pem`.
Both tests have only `all-steps-complete` criteria and no wait steps — the full playlist
completes in under a minute.

Add the `ssl-client-cert` header (URL-encoded cert) to all device simulation requests.

> **Playlist compatibility note:** not all test pairs work together. Tests that have immediate_start: true are unlikely to work in playlists. In CACTUS production these are forbidden as part of playlists and can only be run as individual tests. ALL-05 works here because it has no content-check criteria. Tests like ALL-03 with strict `end-device-contents` criteria should be run standalone with a fresh stack.

### Initialise

```bash
curl -s -X POST http://localhost:18080/initialise \
  -H 'Content-Type: application/json' \
  -d @example-playlist.json
```

Both tests use `immediate_start: true` — they start automatically when initialised or
advanced to. No `/start` call needed.

### ALL-01 device requests

```
GET http://localhost:18080/dcap
GET http://localhost:18080/edev
GET http://localhost:18080/tm
GET http://localhost:18080/edev/1/der
```

### Finalise ALL-01 (auto-advances to ALL-05)

```bash
curl -s -X POST http://localhost:18080/finalize -o all01.zip
```

### ALL-05 device requests

```
GET  http://localhost:18080/dcap
GET  http://localhost:18080/edev
GET  http://localhost:18080/tm

POST http://localhost:18080/edev
     Content-Type: application/sep+xml
     Body:
       <EndDevice xmlns="urn:ieee:std:2030.5:ns">
         <lFDI>504CBE1BB6C3E36EC5C0080F8F785D2585621D69</lFDI>
         <sFDI>215553069392</sFDI>
         <changedTime>1700000000</changedTime>
       </EndDevice>

GET  http://localhost:18080/edev/1/fsa
GET  http://localhost:18080/edev/1/der
```

### Finalise ALL-05

```bash
curl -s -X POST http://localhost:18080/finalize -o all05.zip
```

Each ZIP contains `test_procedure_summary.json`, runner log, and envoy logs.

---

## Teardown

```bash
podman rm -f envoy-svc-local-fwd                 # the port-forward helper
uv run python spawn_local.py down                # removes the pod + its shared volume
```
