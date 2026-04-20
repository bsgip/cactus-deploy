FROM python:3.12-slim-bookworm
ARG ENVOY_VERSION
ARG GITHUB_ORG=bsgip

WORKDIR /app

# Deps
RUN apt update && apt install --no-install-recommends -y netcat-traditional git && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir git+https://git@github.com/${GITHUB_ORG}/envoy.git@${ENVOY_VERSION}#egg=envoy python-json-logger uvicorn

# logging config
COPY logconf.admin.json ./logconf.admin.json
COPY logconf.notification.json ./logconf.notification.json
COPY logconf.server.json ./logconf.server.json
RUN mkdir /shared

# configurables
ENV APP_MODULE="envoy.server.main:app"
ENV WORKERS=1
ENV LOG_CONFIG=logconf.server.json
ENV HOST=0.0.0.0
ENV PORT=8000

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
