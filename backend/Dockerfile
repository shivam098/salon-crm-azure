# Backend API (Express 4, CommonJS). Build context is ./backend.
#
# Debian slim rather than Alpine because `puppeteer` (PDF receipt generation) needs
# a glibc Chromium. We install the distro Chromium and skip Puppeteer's own ~170MB
# download; Puppeteer picks it up via PUPPETEER_EXECUTABLE_PATH.
#
# SECURITY: no secrets are passed as build args. JWT_SECRET, MONGODB_URI, API keys
# etc. are read from process.env at runtime (Container Apps secrets / Key Vault).

FROM node:20-bookworm-slim AS deps
WORKDIR /app
ENV PUPPETEER_SKIP_DOWNLOAD=true
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:20-bookworm-slim AS runner
WORKDIR /app

ENV NODE_ENV=production \
    PORT=3001 \
    PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      chromium \
      fonts-liberation \
      ca-certificates \
      curl \
      tini \
 && rm -rf /var/lib/apt/lists/*

COPY --from=deps /app/node_modules ./node_modules
COPY . .

RUN useradd -m -u 1001 api && chown -R api:api /app
USER api

EXPOSE 3001

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD curl -fsS http://127.0.0.1:${PORT}/health || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "server.js"]
