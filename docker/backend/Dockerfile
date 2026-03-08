FROM ghcr.io/ggml-org/llama.cpp:server-cuda

USER root
WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY docker/backend/entrypoint.sh /usr/local/bin/toolhub-backend-entrypoint.sh
COPY docker/backend/entrypoint_helpers.sh /usr/local/bin/toolhub-backend-helpers.sh

RUN chmod +x /usr/local/bin/toolhub-backend-entrypoint.sh /usr/local/bin/toolhub-backend-helpers.sh

ENTRYPOINT ["/usr/local/bin/toolhub-backend-entrypoint.sh"]
