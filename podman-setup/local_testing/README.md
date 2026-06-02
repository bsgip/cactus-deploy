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
podman-compose down -v
```
