FROM oven/bun:latest AS builder
WORKDIR /app

ARG GBRAIN_TAG=latest

RUN apt-get update && apt-get install -y git openssh-client gawk coreutils && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    if [ "${GBRAIN_TAG}" = "latest" ]; then \
        git ls-remote --tags --refs https://github.com/garrytan/gbrain.git 'refs/tags/v*' \
            | awk '{ sub("refs/tags/", "", $2); print $2 }' \
            | sort -V \
            > /tmp/gbrain-tags; \
        RESOLVED_GBRAIN_TAG="$(tail -n 1 /tmp/gbrain-tags)"; \
    else \
        RESOLVED_GBRAIN_TAG="${GBRAIN_TAG}"; \
    fi; \
    if [ -z "${RESOLVED_GBRAIN_TAG}" ]; then \
        echo "Unable to resolve a gbrain version tag from GBRAIN_TAG=${GBRAIN_TAG}" >&2; \
        exit 1; \
    fi; \
    echo "Building gbrain from tag ${RESOLVED_GBRAIN_TAG}"; \
    git clone --depth 1 --branch "${RESOLVED_GBRAIN_TAG}" https://github.com/garrytan/gbrain.git .

RUN bun install --frozen-lockfile --registry https://registry.npmjs.org
RUN bun run build

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