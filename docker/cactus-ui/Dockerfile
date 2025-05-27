# BUILD stage
FROM python:3.12-slim AS build

RUN apt update && apt install --no-install-recommends -y git && rm -rf /var/lib/apt/lists/*

# Install deps
RUN pip install --no-cache-dir uvicorn git+ssh://git@github.com/bsgip/cactus-ui.git && pip uninstall -y cactus-ui
RUN mkdir /app
RUN pip install --no-cache-dir --no-deps --target /app/ git+ssh://git@github.com/bsgip/cactus-ui.git


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

# Replace static dir
COPY  static cactus_ui/static

# Entrypoint
CMD ["uvicorn", "--host", "0.0.0.0", "--port", "8080", "--workers", "1", "--interface", "wsgi", "cactus_ui.server:app"]
