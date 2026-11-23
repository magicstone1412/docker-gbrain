FROM oven/bun:1.4.4 AS builder
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
    git clone --depth 1 --branch "${RESOLVED_GBRAIN_TAG}" https://github.com/garrytan/gbrain.git .; \
    RESOLVED_GBRAIN_COMMIT="$(git rev-parse HEAD)"; \
    printf 'tag=%s\ncommit=%s\n' "$RESOLVED_GBRAIN_TAG" "$RESOLVED_GBRAIN_COMMIT" > /app/.gbrain-build-info; \
    echo "Building gbrain from tag ${RESOLVED_GBRAIN_TAG} (${RESOLVED_GBRAIN_COMMIT})"

RUN bun install --frozen-lockfile --registry https://registry.npmjs.org
RUN bun run build

FROM oven/bun:1.4.4
WORKDIR /app

ARG GBRAIN_TAG=latest
LABEL org.opencontainers.image.source="https://github.com/garrytan/gbrain" \
      org.gbrain.requested-tag="${GBRAIN_TAG}"

# util-linux provides setpriv, used by the entrypoint to drop privileges (PUID/PGID).
RUN apt-get update && apt-get install -y git openssh-client netcat-openbsd postgresql-client jq util-linux && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app /app
# Root OR non-root: no USER instruction on purpose. The entrypoint runs as
# whatever the container is started as (root by default; PUID/PGID drops
# privileges; `user:` in compose also works).
# oven/bun already ships uid 1000 (user "bun"); only create one if it is absent.
# GBRAIN_HOME is a neutral, persistent home shared by every mode (config in
# $GBRAIN_HOME/.gbrain, ssh keys in $GBRAIN_HOME/.ssh). It is pre-owned by uid
# 1000 so `user: "1000:1000"` works without any chown.
ENV GBRAIN_HOME=/home/gbrain
# Lets every ssh client in the container (entrypoint children AND `docker exec`
# shells, whatever user/HOME) pick up the keys the entrypoint prepares at
# runtime. A missing Include target is silently ignored.
RUN mkdir -p /etc/ssh/ssh_config.d \
    && echo 'Include /home/gbrain/.ssh-runtime/ssh_config' > /etc/ssh/ssh_config.d/50-gbrain.conf
RUN ln -s /app/bin/gbrain /usr/local/bin/gbrain \
    && chmod -R a+rX /app \
    && (getent passwd 1000 >/dev/null || useradd -u 1000 -U -M -d /home/gbrain -s /bin/sh gbrain) \
    && mkdir -p /data/brain /home/gbrain/.gbrain \
    && chown 1000:1000 /data /data/brain /home/gbrain /home/gbrain/.gbrain

COPY entrypoint.sh /entrypoint.sh
# Strip CRLF line endings (a CRLF shebang makes the container fail to start
# with "no such file or directory") and make the script executable.
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

VOLUME ["/data/brain"]
EXPOSE 7333

ENTRYPOINT ["/entrypoint.sh"]
