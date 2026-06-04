#!/usr/bin/env python3
"""Spawn a real teststack pod locally via cactus-orchestrator's PodmanTeststackManager.

This uses the *exact* wiring the orchestrator runs in production — one pod on cactus-net, the runner
as the sole 0.0.0.0 ingress, internals bound to localhost — so there is no separate compose file to
drift out of sync.

Requires:
  * a rootful podman socket (PODMAN_SOCKET, default /run/podman/podman.sock)
  * cactus-net to exist (`podman network create cactus-net`)
  * the `cactus-orchestrator` package importable — run from its venv, e.g.
        uv run python spawn_local.py up

Override images / socket / network via env — see sample.env. Sensible local defaults are applied.

Usage:
    python spawn_local.py up   [TESTSTACK_ID]    # spawn  (default id: local)
    python spawn_local.py down [TESTSTACK_ID]    # tear down
"""

import asyncio
import dataclasses
import json
import os
import sys

# NOTE: these tags must be a build that implements the current entrypoint contract the orchestrator
# relies on — runner binds ${HOST}:${PORT}; teststack-init writes $MIGRATION_SENTINEL; envoy waits on
# it. 1.2 uses the "-v12" images (envoy 1.x), 1.3 the "-v13" images (envoy 2.x). Keep the tags in sync
# with ../../docker/versions.lock.
_DEFAULT_IMAGES = {
    "1.2": {
        "postgres": "docker.io/library/postgres:15",
        "pubsub": "docker.io/library/rabbitmq:3",
        "teststack_init": "cactusimageregistry.azurecr.io/cactus-teststack-init:podman-v12",
        "envoy": "cactusimageregistry.azurecr.io/cactus-envoy:podman-v12",
        "runner": "cactusimageregistry.azurecr.io/cactus-runner:podman-v12",
    },
    "1.3": {
        "postgres": "docker.io/library/postgres:15",
        "pubsub": "docker.io/library/rabbitmq:3",
        "teststack_init": "cactusimageregistry.azurecr.io/cactus-teststack-init:podman-v13",
        "envoy": "cactusimageregistry.azurecr.io/cactus-envoy:podman-v13",
        "runner": "cactusimageregistry.azurecr.io/cactus-runner:podman-v13",
    },
}

os.environ.setdefault("ORCHESTRATOR_DATABASE_URL", "postgresql+asyncpg://unused:unused@localhost/unused")
os.environ.setdefault("TEST_EXECUTION_FQDN", "localhost")
os.environ.setdefault("PODMAN_SOCKET", "/run/podman/podman.sock")
os.environ.setdefault("PODMAN_NETWORK", "cactus-net")
os.environ.setdefault("PODMAN_TESTSTACK_IMAGES", json.dumps(_DEFAULT_IMAGES))

from cactus_orchestrator.settings import get_current_settings  # noqa: E402
from cactus_orchestrator.teststack import manager  # noqa: E402  (env must be set before import)


def _split_ref(ref: str) -> tuple[str, str]:
    """Split an image reference into (repository, tag), tolerating a registry host:port."""
    if ":" in ref.rsplit("/", 1)[-1]:
        repo, tag = ref.rsplit(":", 1)
        return repo, tag
    return ref, "latest"


def _pull_images(csip_aus_version: str) -> None:
    """Pull this version's teststack images if absent.

    The orchestrator never pulls — it fails fast when an image is missing, since in production images
    are pre-pulled at deploy time (setup.sh). This local helper does the pull so a fresh box needs no
    manual `podman pull`.
    """
    images = get_current_settings().podman_teststack_images.get(csip_aus_version)
    if images is None:
        return  # let manager.spawn raise the clear "no image config" error
    with manager._client() as client:
        for ref in dict.fromkeys(dataclasses.astuple(images)):
            if client.images.exists(ref):
                continue
            print(f"pulling {ref} ...")
            client.images.pull(*_split_ref(ref))


async def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "up"
    teststack_id = sys.argv[2] if len(sys.argv) > 2 else "local"
    csip_aus_version = os.environ.get("CSIP_AUS_VERSION", "1.3")
    pod = manager._pod_name(teststack_id)

    if cmd == "up":
        _pull_images(csip_aus_version)
        names = await manager.spawn(teststack_id, csip_aus_version, "local-dev")
        print(f"pod '{pod}' up — runner control URL (on cactus-net): {names.runner_base_url}")
        print("the pod publishes no host port (matches prod); see README.md to forward the runner.")
        return 0
    if cmd == "down":
        await manager.destroy(teststack_id)
        print(f"pod '{pod}' destroyed")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
