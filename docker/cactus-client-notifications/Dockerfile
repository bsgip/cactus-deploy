# BUILD stage
FROM python:3.12-slim AS build
ARG CACTUS_CLIENT_NOTIFICATIONS_VERSION
ARG GITHUB_ORG=bsgip

RUN apt-get update; apt-get install -y git openssh-client

# Setup the git config to use https
RUN git config --global url."https://git@github.com/".insteadOf "ssh://git@github.com/"

# Install app / dependencies
RUN pip install --no-cache-dir "cactus-client-notifications[server] @ git+ssh://git@github.com/${GITHUB_ORG}/cactus-client-notifications.git@${CACTUS_CLIENT_NOTIFICATIONS_VERSION}" gunicorn

# RUN stage
FROM  python:3.12-slim


WORKDIR /app

# Copy env
COPY --from=build --chown=appuser:appuser /usr/local/lib/  /usr/local/lib/
COPY --from=build --chown=appuser:appuser /usr/local/bin/  /usr/local/bin/

# conf
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV APP_HOST='0.0.0.0'
ENV APP_PORT='8080'

# run app
CMD ["sh", "-c", "exec gunicorn cactus_client_notifications.server.main:app --bind ${APP_HOST}:${APP_PORT} --worker-class aiohttp.GunicornWebWorker"]

