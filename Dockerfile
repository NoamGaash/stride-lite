# One image for everything that talks to ClickHouse from outside it: the API,
# the schema and migrations, and the ingest and archive jobs. Which one runs is
# the command; where ClickHouse is comes from the environment (deploy/hasadna/).
FROM clickhouse/clickhouse-server:26.10 AS clickhouse

FROM node:26-bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl python3 awscli unzip zstd \
 && rm -rf /var/lib/apt/lists/*
# The client only; the server runs elsewhere. Same release as the server.
COPY --from=clickhouse /usr/bin/clickhouse /usr/local/bin/clickhouse

WORKDIR /app
COPY api/package.json api/package-lock.json api/
RUN cd api && npm ci && npm cache clean --force
COPY api api
COPY db db
COPY ingest ingest
COPY scripts scripts

ENV NODE_ENV=production CH_DB=stride PORT=8080
USER node
WORKDIR /app/api
EXPOSE 8080
CMD ["npx", "tsx", "src/server.ts"]
