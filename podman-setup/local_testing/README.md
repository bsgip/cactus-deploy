# Local testing — teststack smoke test

> **This entire directory is for local development only.**
> In production the orchestrator manages teststack pods directly via the Podman API.
> None of this is used in a real deployment.

Runs the full teststack locally via `podman-compose` so you can drive the runner API
directly without the orchestrator, simulating DER device requests from an HTTP client
(Postman, curl, etc.).

---

## Prerequisites

```bash
apt install podman
pip install podman-compose
```

Images are pulled from `cactusimageregistry.azurecr.io` (public — no login needed).

---

## Start

```bash
cp sample.env .env        # edit image tags if needed
podman-compose up -d
```

Wait for healthy (~60 s):

```bash
podman ps --format "table {{.Names}}\t{{.Status}}"
curl http://localhost:18080/health
curl "http://localhost:18000/status/version?check_data=false"
```

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

All endpoints at `http://localhost:18080`.

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/health` | Liveness / version |
| `GET` | `/status` | Current test state and criteria |
| `POST` | `/initialise` | Load a test or playlist, apply preconditions |
| `POST` | `/start` | Enable the first test step |
| `POST` | `/finalize` | End the test; returns ZIP with PDF report + logs |
| `*` | `/<anything else>` | Proxied to envoy — simulate the DER device here |

---

## Example: ALL-01 + ALL-03 playlist

`example-playlist.json` contains a two-test playlist using `test-client.cert.pem`.

Add the `ssl-client-cert` header (URL-encoded cert) to all device simulation requests.

### Initialise

```bash
curl -s -X POST http://localhost:18080/initialise \
  -H 'Content-Type: application/json' \
  -d @example-playlist.json
```

ALL-01 uses `immediate_start: true` — starts automatically, no `/start` needed.

### ALL-01 device requests

```
GET http://localhost:18080/dcap
GET http://localhost:18080/edev
GET http://localhost:18080/tm
GET http://localhost:18080/edev/1/der
```

### Finalise ALL-01 (auto-advances to ALL-03)

```bash
curl -s -X POST http://localhost:18080/finalize -o all01.zip
```

### Start ALL-03

```bash
curl -s -X POST http://localhost:18080/start
```

### ALL-03 device requests

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

GET  http://localhost:18080/edev/1/der

PUT  http://localhost:18080/edev/1/cp
     Content-Type: application/sep+xml
     Body:
       <csipaus:ConnectionPoint
           xmlns="urn:ieee:std:2030.5:ns"
           xmlns:csipaus="https://csipaus.org/ns"
           xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
           xsi:type="" href="">
         <csipaus:id></csipaus:id>
         <csipaus:connectionPointId>1234567890</csipaus:connectionPointId>
       </csipaus:ConnectionPoint>
```

### Finalise ALL-03

```bash
curl -s -X POST http://localhost:18080/finalize -o all03.zip
```

Each ZIP contains `test_procedure_summary.json`, runner log, and envoy logs.

---

## Teardown

```bash
podman-compose down -v
```
