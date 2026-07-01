# Mock mTLS Subscription Notification Endpoint

Really simple service for implementing an mTLS enabled endpoint for testing the CACTUS mTLS implementation

It's a Minimal nginx image that returns `200` for `POST /endpoint`, secured with mTLS. It serves a specific cert chain and only accepts client certs issued from a specific chain.

## Prerequisites

Place these four files in the same directory as the `Dockerfile` before building:

| File | Purpose |
|---|---|
| `serca.pem` | Root CA shared by both chains |
| `utility-server-fullchain.pem` | Full signing chain of the client cert this endpoint must trust |
| `certificate.pfx` | Cert + key this endpoint will present (no import password) |
| `fullchain.pem` | Full chain (leaf..root) matching `certificate.pfx` |

The DNS SAN is read automatically from `certificate.pfx` and used as `server_name` — no manual config needed.

## Build

```bash
podman build -t mtls-mock-webhook .
```

## Run

```bash
podman run --rm -p 8443:443 mtls-mock-webhook
```