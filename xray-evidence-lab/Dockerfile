# syntax=docker/dockerfile:1.7
ARG REPO_URL

# Stage 1: resolve dependencies through Artifactory.
# The .npmrc arrives as a BuildKit secret so the Artifactory token never lands in a layer.
FROM ${REPO_URL}/node:20-alpine AS builder

WORKDIR /app

COPY package.json ./

RUN --mount=type=secret,id=npmrc,target=/root/.npmrc \
    npm install --omit=dev --no-audit --no-fund

COPY server.js ./

# Stage 2: runtime image
FROM ${REPO_URL}/node:20-alpine

WORKDIR /app

COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/server.js ./server.js

EXPOSE 3000

CMD ["node", "server.js"]
