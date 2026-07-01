# PKI — generating the CACTUS certificate chains

`create-cert.sh` generates the emulated IEEE 2030.5 / NEPKI signing chains the orchestrator and the
nginx edge use. All chains share one **SERCA** root. The orchestrator loads these to issue device /
aggregator leaf certs on demand and to present the utility-server (envoy / DNSP) identity for
notification mTLS.

```
create-cert.sh PROFILE SERCA_ID SERCA_SERIAL [CHAIN_ID CHAIN_SERIAL] [EE_NAME EE_SERIAL [EE_DNS]]
```

`PROFILE` is `device`, `aggregator`, or `dnsp`. Re-running with an existing `SERCA_ID` reuses (does
not regenerate) the SERCA, so all three chains below chain to the same root. Outputs are written to
`./<SERCA_ID>/`, `./<CHAIN_ID>/`, and `./<EE_NAME>/` relative to the cwd.

## 1. Generate the three chains (one shared SERCA)

Run from this directory. The device and aggregator chains stop at the CA level — the orchestrator
mints their End-Entity leaves at runtime. The DNSP chain additionally generates the **static wildcard
envoy EE** that envoy presents on outbound notifications.

Its wildcard SAN must equal `*.${CACTUS_FQDN}` — the same FQDN that drives nginx's `server_name` — so a
single static cert covers every per-pod hostname. Derive it from `cactus.env` rather than hand-typing,
so the two can't drift (or set `CACTUS_FQDN` by hand if generating on an offline host):

```bash
source ../server/cactus.env   # provides CACTUS_FQDN

# Device chain:      SERCA -> MCA -> MICA            (orchestrator mints device EEs)
./create-cert.sh device     serca 1 cactus-chain     1

# Aggregator chain:  SERCA -> Services PCA -> Agg ICA (orchestrator mints aggregator EEs)
./create-cert.sh aggregator serca 1 aggregator-chain 2

# DNSP chain + static wildcard envoy EE: SERCA -> Services PCA -> DNSP ICA -> envoy EE
./create-cert.sh dnsp       serca 1 dnsp-chain       3 envoy 1 "*.${CACTUS_FQDN}"
```

Outputs (note device labels are upper-case `MCA`/`MICA`; services labels are lower-case `pca`/`ica`):

```
serca/serca.cert.pem  serca/serca.key.pem
cactus-chain/MCA.cert.pem   cactus-chain/MICA.cert.pem   cactus-chain/MICA.key.pem
aggregator-chain/pca.cert.pem   aggregator-chain/ica.cert.pem   aggregator-chain/ica.key.pem
dnsp-chain/pca.cert.pem   dnsp-chain/ica.cert.pem   dnsp-chain/ica.key.pem
envoy/envoy.cert.pem   envoy/envoy.key.pem   envoy/envoy.fullchain.pem
```

## 2. Stage into `/etc/cactus/pki/` (the paths in `server/cactus.env`)

`stage-certs.sh` copies **only what the orchestrator needs** to the host paths referenced by the
`CERT_*` vars in `cactus.env`, with `cactus:cactus` ownership and least-privilege modes (keys 640,
certs 644, dirs 750). Of the private keys the host gets **only** the MICA, aggregator ICA, and envoy EE
keys; the **SERCA / MCA / PCA / DNSP-ICA private keys are never copied** (least privilege — see
`docs/certificate-design.md` §7).

```bash
# <create-cert-output-dir> is where you ran the commands in §1 (this dir if run from here)
sudo ./stage-certs.sh . ../server/cactus.env
```

It validates up front and refuses to half-stage: a missing source file or an unset `CERT_*` var aborts
with the full list. Re-run any time to restage rotated certs.

> `CERT_ENVOY_EE_FULLCHAIN_PATH` points at the pre-assembled `envoy.fullchain.pem` (EE + DNSP ICA + PCA,
> excluding SERCA). The orchestrator stages it for notification mTLS and serves it verbatim in the
> `GET /certificate/authority` bundle, so it no longer needs the separate DNSP PCA/ICA certs.

## 3. nginx edge cert (separate)

The public-facing utility-server TLS used by nginx (`CERT_SERVER_CERT_FULLCHAIN_PATH` /
`CERT_SERVER_KEY_PATH`) and the orchestration-domain TLS (Let's Encrypt) are **not** part of the
SERCA hierarchy above — see `server/nginx-config.sh`.
