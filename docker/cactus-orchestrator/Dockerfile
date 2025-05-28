# BUILD stage
FROM python:3.12-slim AS build
ARG CACTUS_ORCHESTRATOR_VERSION

RUN apt update && apt install --no-install-recommends -y git openssh-client && rm -rf /var/lib/apt/lists/*

# Setup the git config to use https
RUN git config --global url."https://git@github.com/".insteadOf "ssh://git@github.com/"

# Install deps
RUN pip install --no-cache-dir uvicorn git+ssh://git@github.com/bsgip/cactus-orchestrator.git@${CACTUS_ORCHESTRATOR_VERSION}

# RUN stage
FROM python:3.12-slim

RUN useradd -ms /bin/bash appuser
USER appuser

# Copy env
COPY --from=build --chown=appuser:appuser /usr/local/lib/  /usr/local/lib/
COPY --from=build --chown=appuser:appuser /usr/local/bin/  /usr/local/bin/

# conf
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Entrypoint
CMD ["uvicorn", "--host", "0.0.0.0", "--port", "8080", "--workers", "1", "cactus_orchestrator.main:app"]
