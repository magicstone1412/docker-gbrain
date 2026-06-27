FROM oven/bun:latest
WORKDIR /app

RUN apt-get update && apt-get install -y git openssh-client netcat-openbsd postgresql-client jq && rm -rf /var/lib/apt/lists/*

RUN bun install -g github:garrytan/gbrain --registry https://registry.npmjs.org

RUN mkdir -p /data/brain

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/data/brain"]
EXPOSE 7333

ENTRYPOINT ["/entrypoint.sh"]