# UV Docker best practices: https://docs.astral.sh/uv/guides/integration/docker/
# BUILD stage
FROM python:3.12-slim-bookworm AS builder
COPY --from=ghcr.io/astral-sh/uv:0.11.16 /uv /bin/uv

ARG CACTUS_CLIENT_NOTIFICATIONS_VERSION
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
RUN git clone --depth 1 --branch ${CACTUS_CLIENT_NOTIFICATIONS_VERSION} \
    https://github.com/${GITHUB_ORG}/cactus-client-notifications.git . || \
    (git clone https://github.com/${GITHUB_ORG}/cactus-client-notifications.git . && \
     git checkout ${CACTUS_CLIENT_NOTIFICATIONS_VERSION})

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-editable --extra server && \
    uv pip install gunicorn

# RUN stage
FROM python:3.12-slim-bookworm

WORKDIR /app

COPY --from=builder /app/.venv /app/.venv

# conf
ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV APP_HOST='0.0.0.0'
ENV APP_PORT='8080'

# run app
CMD ["sh", "-c", "exec gunicorn cactus_client_notifications.server.main:app --bind ${APP_HOST}:${APP_PORT} --worker-class aiohttp.GunicornWebWorker"]
