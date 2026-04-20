# BUILD stage
FROM python:3.12-slim AS build
ARG CACTUS_UI_VERSION
ARG GITHUB_ORG=bsgip

RUN apt update && apt install --no-install-recommends -y git openssh-client && rm -rf /var/lib/apt/lists/*

# Setup the git config to use https
RUN git config --global url."https://git@github.com/".insteadOf "ssh://git@github.com/"

# Install deps
RUN pip install --no-cache-dir uvicorn git+ssh://git@github.com/${GITHUB_ORG}/cactus-ui.git@${CACTUS_UI_VERSION} && pip uninstall -y cactus-ui
RUN mkdir /app
RUN pip install --no-cache-dir --no-deps --target /app/ git+ssh://git@github.com/${GITHUB_ORG}/cactus-ui.git@${CACTUS_UI_VERSION}

# Copy static dependencies (seperate dir) - we will merge them with what was installed in the python build
COPY static /tmp/static
RUN cp -rn /tmp/static/* /app/cactus_ui/static/




# RUN stage
FROM python:3.12-slim

RUN useradd -ms /bin/bash appuser
USER appuser
WORKDIR /home/appuser/app/

# Copy env
COPY --from=build --chown=appuser:appuser /app/ /home/appuser/app/
COPY --from=build --chown=appuser:appuser /usr/local/lib/  /usr/local/lib/
COPY --from=build --chown=appuser:appuser /usr/local/bin/  /usr/local/bin/

# conf
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
COPY ./logconf.json /home/appuser/app/logconf.json

# Entrypoint
CMD ["uvicorn", "--host", "0.0.0.0", "--port", "8080", "--workers", "1", "--interface", "wsgi", "cactus_ui.server:app"]
