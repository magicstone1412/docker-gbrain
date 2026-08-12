FROM oven/bun:latest AS builder
WORKDIR /app

ARG GBRAIN_TAG=latest

RUN apt-get update && apt-get install -y git openssh-client gawk coreutils && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    if [ "${GBRAIN_TAG}" = "latest" ]; then \
        RESOLVED_GBRAIN_TAG="$(git ls-remote --tags --refs https://github.com/garrytan/gbrain.git 'refs/tags/v*' \
            | awk '{ sub("refs/tags/", "", $2); print $2 }' \
            | sort -V \
            | tail -n 1)"; \
    else \
        RESOLVED_GBRAIN_TAG="${GBRAIN_TAG}"; \
    fi; \
    test -n "${RESOLVED_GBRAIN_TAG}"; \
    git clone --depth 1 --branch "${RESOLVED_GBRAIN_TAG}" https://github.com/garrytan/gbrain.git .; \
    bun install --frozen-lockfile --registry https://registry.npmjs.org; \
    bun run build

FROM oven/bun:latest
WORKDIR /app

RUN apt-get update && apt-get install -y git openssh-client netcat-openbsd postgresql-client jq && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app /app
RUN ln -s /app/bin/gbrain /usr/local/bin/gbrain \
    && mkdir -p /data/brain

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/data/brain"]
EXPOSE 7333

ENTRYPOINT ["/entrypoint.sh"]