# UV Docker best practices: https://docs.astral.sh/uv/guides/integration/docker/
# BUILD stage
FROM python:3.12-slim-bookworm AS builder
COPY --from=ghcr.io/astral-sh/uv:0.11.16 /uv /bin/uv

ARG CACTUS_RUNNER_VERSION
ARG GITHUB_ORG=bsgip

# pre-compile .pyc at build time for faster startup; copy instead of hardlink (cache mount
# requirement); strip dev deps; use the image's Python rather than downloading a new one
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_NO_DEV=1 \
    UV_PYTHON_DOWNLOADS=0

RUN apt-get update && apt-get install --no-install-recommends -y git && rm -rf /var/lib/apt/lists/*

# Clone so uv can read pyproject.toml + uv.lock for a fully locked install.
# Previously pip install git+... was used but couldn't leverage the lock file.
WORKDIR /app
RUN git clone --depth 1 --branch ${CACTUS_RUNNER_VERSION} \
    https://github.com/${GITHUB_ORG}/cactus-runner.git . || \
    (git clone https://github.com/${GITHUB_ORG}/cactus-runner.git . && \
     git checkout ${CACTUS_RUNNER_VERSION})

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-editable && \
    uv pip install "gunicorn==26.0.0"

# RUN stage
FROM python:3.12-slim-bookworm

# This postgresql-client version shouldn't be "behind" the postgres version in the k8s pod
# eg: If the pod is running postgres:15, don't install postgresql-client-14
RUN apt-get update && apt-get install --no-install-recommends -y postgresql-client && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN mkdir -p config/logging && mkdir /shared
COPY ./logconf.json /app/config/logging/config.json

COPY --from=builder /app/.venv /app/.venv

# conf
ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV APP_HOST='0.0.0.0'
ENV APP_PORT='8080'

# run app
CMD ["sh", "-c", "exec gunicorn cactus_runner.app.main:app --bind ${APP_HOST}:${APP_PORT} --worker-class aiohttp.GunicornWebWorker --timeout 60"]
