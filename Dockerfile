FROM oven/bun:latest AS builder
WORKDIR /app

ARG GBRAIN_TAG=latest

RUN apt-get update && apt-get install -y git openssh-client && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${GBRAIN_TAG}" https://github.com/garrytan/gbrain.git . \
    && bun install --frozen-lockfile --registry https://registry.npmjs.org \
    && bun run build

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