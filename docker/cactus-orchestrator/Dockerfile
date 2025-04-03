FROM python:3.12-slim
WORKDIR /app/

RUN apt update && apt install --no-install-recommends -y git && rm -rf /var/lib/apt/lists/*

# Setup the git config for private repos
RUN --mount=type=secret,id=github_pat,uid=50000 git config --global url."https://ssh:$(cat /run/secrets/github_pat)@github.com/".insteadOf "ssh://git@github.com/"
RUN --mount=type=secret,id=github_pat,uid=50000 git config --global url."https://git:$(cat /run/secrets/github_pat)@github.com/".insteadOf "git@github.com:"

# python conf
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Copy src
COPY ./src /app/src
COPY ./pyproject.toml /app/pyproject.toml

# Install deps
RUN pip install --no-cache-dir -e /app && pip install --no-cache-dir uvicorn

# Entrypoint
CMD ["uvicorn", "--host", "0.0.0.0", "--port", "8080", "--workers", "1", "cactus_orchestrator.main:app"]
