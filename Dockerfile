FROM oven/bun:latest
WORKDIR /app

RUN apt-get update && apt-get install -y git netcat-openbsd && rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/garrytan/gbrain .
RUN bun install --registry https://registry.npmjs.org
RUN bun link

RUN mkdir -p /data/brain

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/data/brain"]
EXPOSE 7333

ENTRYPOINT ["/entrypoint.sh"]