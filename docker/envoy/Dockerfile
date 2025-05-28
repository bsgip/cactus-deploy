ARG ENVOY_VERSION

FROM python:3.11-slim-bookworm

WORKDIR /app

# Deps
RUN apt update && apt install --no-install-recommends -y git && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir git+https://git@github.com/bsgip/envoy.git@${ENVOY_VERSION}#egg=envoy python-json-logger uvicorn


# logging config
COPY logconf.json ./logconf.json
RUN mkdir logs

# configurables
ENV APP_MODULE="envoy.server.main:app"
ENV WORKERS=1
ENV LOG_CONFIG=logconf.json
ENV HOST=0.0.0.0
ENV PORT=8000


COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
