#!/usr/bin/env python3
"""Spawn a real teststack pod locally via the orchestrator's teststack manager.

Uses the exact wiring the orchestrator runs in production (one pod on cactus-net, the runner the sole
0.0.0.0 ingress, internals on localhost). Run as root from the cactus-orchestrator venv:

    sudo -E .venv/bin/python spawn_local.py up   [ID]   # spawn   (default ID: local)
    sudo -E .venv/bin/python spawn_local.py down [ID]   # tear down

Override images / socket / network via env — see sample.env.
"""

import asyncio
import dataclasses
import json
import logging
import os
import sys

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

# Default teststack images per CSIP-Aus version (1.2 -> -v12 / envoy 1.x, 1.3 -> -v13 / envoy 2.x).
# Keep in sync with ../../docker/versions.lock.
_REGISTRY = "cactusimageregistry.azurecr.io"
_DEFAULT_IMAGES = {
    version: {
        "postgres": "docker.io/library/postgres:15",
        "pubsub": "docker.io/library/rabbitmq:3",
        "teststack_init": f"{_REGISTRY}/cactus-teststack-init:podman-{tag}",
        "envoy": f"{_REGISTRY}/cactus-envoy:podman-{tag}",
        "runner": f"{_REGISTRY}/cactus-runner:podman-{tag}",
    }
    for version, tag in (("1.2", "v12"), ("1.3", "v13"))
}

os.environ.setdefault("ORCHESTRATOR_DATABASE_URL", "postgresql+asyncpg://unused:unused@localhost/unused")
os.environ.setdefault("TEST_EXECUTION_FQDN", "localhost")
os.environ.setdefault("PODMAN_SOCKET", "/run/podman/podman.sock")
os.environ.setdefault("PODMAN_NETWORK", "cactus-net")
os.environ.setdefault("PODMAN_TESTSTACK_IMAGES", json.dumps(_DEFAULT_IMAGES))

from cactus_orchestrator.settings import get_current_settings  # noqa: E402
from cactus_orchestrator.teststack import manager  # noqa: E402  (env must be set before import)


def _pull_missing_images(csip_aus_version: str) -> None:
    """Pre-pull this version's images. The manager lazy-pulls most containers, but creates the runner via
    the raw API which won't, so a fresh box needs the images present first."""
    images = get_current_settings().podman_teststack_images.get(csip_aus_version)
    if images is None:
        return  # let manager.spawn raise the clear "no image config" error
    with manager._client() as client:
        for ref in dict.fromkeys(dataclasses.astuple(images)):
            if not client.images.exists(ref):
                print(f"pulling {ref} ...")
                client.images.pull(ref)


async def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "up"
    teststack_id = sys.argv[2] if len(sys.argv) > 2 else "local"
    csip_aus_version = os.environ.get("CSIP_AUS_VERSION", "1.3")

    if cmd == "up":
        _pull_missing_images(csip_aus_version)
        names = await manager.spawn(teststack_id, csip_aus_version, "local-dev")
        print(f"pod up — runner (cactus-net): {names.runner_base_url}  (no host port; reach it via Traefik)")
        return 0
    if cmd == "down":
        await manager.destroy(teststack_id)
        print(f"pod '{manager._pod_name(teststack_id)}' destroyed")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
