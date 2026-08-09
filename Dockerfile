# Frontend (Next.js 16 App Router) — standalone output.
# Build context is the repo root.
#
# SECURITY: never pass secrets as --build-arg (they are baked into image layers and
# readable via `docker history`). Only NEXT_PUBLIC_* values, which are public by
# definition, are accepted at build time. Everything else is read from the
# environment at runtime.

FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

FROM node:20-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Baked into the client bundle at build time — public values only.
ARG NEXT_PUBLIC_API_URL=/api
ARG NEXT_PUBLIC_SITE_URL
ARG NEXT_PUBLIC_ENVIRONMENT=production
# next.config.mjs evaluates rewrites() during `next build`, so the proxy target is
# resolved here, not at runtime. It is an internal hostname, not a secret.
ARG API_PROXY_TARGET=http://backend:3001
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL \
    NEXT_PUBLIC_SITE_URL=$NEXT_PUBLIC_SITE_URL \
    NEXT_PUBLIC_ENVIRONMENT=$NEXT_PUBLIC_ENVIRONMENT \
    API_PROXY_TARGET=$API_PROXY_TARGET \
    NEXT_TELEMETRY_DISABLED=1

RUN npm run build

FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

RUN addgroup -g 1001 -S nodejs && adduser -S nextjs -u 1001

COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs
EXPOSE 3000

# API_PROXY_TARGET is baked in at build time (see builder stage). Rebuild with a
# different --build-arg to point the /api proxy at another backend.
CMD ["node", "server.js"]
