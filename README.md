# EaseMySalon CRM — Azure-hosted copy

A salon and spa management system: appointment scheduling, point-of-sale, client
management, inventory and reporting.

> **This is a personal learning copy** of [`EaseMySalon-HQ/salon-crm`](https://github.com/EaseMySalon-HQ/salon-crm),
> re-scaffolded to run in containers on **Azure** instead of Railway.
> See [What changed from upstream](#what-changed-from-upstream).

---

## Architecture

Two independently deployable services plus two backing stores:

```
browser ──► frontend (Next.js 16, :3000)
                │  /api/* rewritten server-side (same-origin cookies)
                ▼
            backend (Express 4, :3001) ──► MongoDB   (per-tenant databases)
                                       └─► Redis     (cache, rate limits, BullMQ)
```

The frontend proxies `/api` to the backend rather than calling it cross-origin, so
tenant `HttpOnly` session cookies stay same-origin. Keep this arrangement — the
cross-origin variant breaks on iPad/WebKit.

## Tech stack

| Layer | Choice |
|---|---|
| Frontend | Next.js 16 App Router, React 19, TypeScript, Tailwind, shadcn/ui |
| Backend | Node.js 20, Express 4, CommonJS |
| Database | MongoDB 7 / Mongoose 8, multi-tenant (a database per salon) |
| Cache & queues | Redis 7, BullMQ |
| Containers | Docker (Next.js `standalone` output; Debian slim for the API) |

---

## Quick start

### Option A — Docker (whole stack, closest to production)

```bash
cp env.example .env
cp backend/env.example backend/.env      # then fill in JWT_SECRET
docker compose up --build
```

- Frontend → http://localhost:3000
- API health → http://localhost:3001/health

MongoDB and Redis run as compose services; no local install needed.

### Option B — Node directly

```bash
npm install
npm install --prefix backend

cp backend/env.example backend/.env      # set JWT_SECRET + MONGODB_URI
cp env.example .env.local

npm run dev:all                          # frontend + backend together
```

You need MongoDB reachable at `MONGODB_URI`. Redis is optional — the app fails
open (cache and rate limiting degrade gracefully) when `REDIS_URL` is unset.

---

## Configuration

Secrets are **never** committed. `.env*` and `config.env` are gitignored; the
`env.example` files are the source of truth for variable names.

### Backend (`backend/.env`)

| Variable | Required | Notes |
|---|---|---|
| `PORT` | no | Defaults to `3001` |
| `MONGODB_URI` | **yes** | Base URI; the app appends per-tenant database names |
| `JWT_SECRET` | **yes** | Long random string — generate a fresh one, never reuse |
| `WHATSAPP_TOKEN_ENC_KEY` | **yes** | 32 bytes (64 hex chars or base64). The server **refuses to start** without it; it encrypts stored WhatsApp tokens at rest |
| `CORS_ORIGIN` | **yes** | Frontend origin, e.g. `https://<your-app>.azurecontainerapps.io` |
| `REDIS_URL` | no | Enables shared cache, rate limits and BullMQ workers |
| `NODE_ENV` / `LOG_LEVEL` | no | `production` / `warn` in the cloud |

Integration keys (Resend/SendGrid email, MSG91 SMS, Gupshup WhatsApp, Razorpay,
Stripe, Google APIs) are optional — those features stay dormant when unset.
`backend/env.example` documents every one.

Generate the two required secrets:

```bash
# JWT_SECRET
node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"

# WHATSAPP_TOKEN_ENC_KEY (must be exactly 32 bytes)
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

Rotating `WHATSAPP_TOKEN_ENC_KEY` makes previously encrypted tokens unreadable.

### Frontend

| Variable | When | Notes |
|---|---|---|
| `NEXT_PUBLIC_API_URL` | build | Keep as `/api` to use the same-origin proxy |
| `API_PROXY_TARGET` | **build** | Backend origin *without* `/api` |
| `NEXT_PUBLIC_SITE_URL` | build | Canonical URL for SEO/sitemap |

> `API_PROXY_TARGET` is a **build argument**, not a runtime variable. Next.js
> resolves `rewrites()` during `next build` and freezes the result into the route
> manifest, so pointing the proxy elsewhere requires rebuilding the image.

---

## Deploying to Azure

Target: **Azure Container Apps** — two container apps in one environment, images
in **Azure Container Registry**. Backend uses internal ingress, frontend external.

### 1. Provision

```bash
RG=salon-crm-rg
LOC=centralindia
ACR=saloncrmacr$RANDOM          # must be globally unique
ENV=salon-crm-env

az group create -n $RG -l $LOC
az acr create -g $RG -n $ACR --sku Basic --admin-enabled true
az containerapp env create -g $RG -n $ENV -l $LOC
```

### 2. Database and cache

- **MongoDB** → *Azure Cosmos DB for MongoDB (vCore)*, or MongoDB Atlas.
  Choose **vCore**, not the RU-based API: this app creates a separate database per
  tenant and relies on standard MongoDB semantics.
- **Redis** → *Azure Managed Redis* / Azure Cache for Redis, using the `rediss://`
  URL. Optional, but needed once more than one replica runs, since rate limits and
  caches are shared through it.

### 3. Build images in ACR

```bash
az acr build -r $ACR -t salon-crm-backend:v1 -f backend/Dockerfile ./backend

az acr build -r $ACR -t salon-crm-frontend:v1 -f Dockerfile . \
  --build-arg API_PROXY_TARGET=http://backend \
  --build-arg NEXT_PUBLIC_API_URL=/api
```

Inside a Container Apps environment, `http://backend` resolves to the backend app
over internal DNS, so frontend→API traffic never leaves the private network.

### 4. Backend app (internal ingress)

```bash
az containerapp create -g $RG -n backend --environment $ENV \
  --image $ACR.azurecr.io/salon-crm-backend:v1 \
  --registry-server $ACR.azurecr.io \
  --target-port 3001 --ingress internal \
  --min-replicas 1 --max-replicas 3 \
  --secrets mongo-uri="<connection-string>" jwt-secret="<generated>" wa-enc-key="<32-byte-hex>" redis-url="<rediss-url>" \
  --env-vars NODE_ENV=production PORT=3001 \
             MONGODB_URI=secretref:mongo-uri \
             JWT_SECRET=secretref:jwt-secret \
             WHATSAPP_TOKEN_ENC_KEY=secretref:wa-enc-key \
             REDIS_URL=secretref:redis-url
```

Secrets are passed as `secretref:` values and resolved at runtime. Never bake them
in with `--build-arg` — build args are stored in image layers and readable via
`docker history`. For anything beyond learning, back them with Key Vault
references instead.

### 5. Frontend app (public ingress)

```bash
az containerapp create -g $RG -n frontend --environment $ENV \
  --image $ACR.azurecr.io/salon-crm-frontend:v1 \
  --registry-server $ACR.azurecr.io \
  --target-port 3000 --ingress external \
  --min-replicas 1 --max-replicas 3
```

Then point the backend's CORS at the FQDN this prints:

```bash
az containerapp update -g $RG -n backend \
  --set-env-vars CORS_ORIGIN="https://<frontend-fqdn>"
```

### 6. Verify

```bash
az containerapp exec -g $RG -n backend --command "curl -s localhost:3001/health"
curl -I https://<frontend-fqdn>
```

`/health` reports MongoDB and Redis status — `redis: "disabled"` just means
`REDIS_URL` was not set.

### Sizing note

Each active tenant opens its own MongoDB pool, so the connection ceiling is:

```
maxReplicas × (MONGO_MAIN_POOL_SIZE + MONGO_MAX_CACHED_TENANTS × MONGO_TENANT_POOL_SIZE)
```

Defaults assume ~1500 available connections across 3 replicas. Recheck this before
raising replica counts or moving to a smaller database tier — the pool variables
are documented in `backend/env.example`.

---

## Project structure

```
salon-crm/
├── app/                  # Next.js App Router pages
├── components/           # React components (shadcn/ui based)
├── lib/                  # API client, shared utilities
├── hooks/                # React hooks
├── backend/
│   ├── server.js         # Express entrypoint
│   ├── routes/           # API routes
│   ├── models/           # Mongoose models
│   ├── services/         # Business logic
│   ├── jobs/             # node-cron schedulers
│   ├── workers/          # BullMQ workers
│   ├── config/           # DB + tenant connection manager
│   └── Dockerfile
├── docs/                 # Feature documentation
├── Dockerfile            # Frontend image
└── docker-compose.yml    # Local full stack
```

## Scripts

| Command | Purpose |
|---|---|
| `npm run dev` | Frontend dev server |
| `npm run dev:backend` | Backend with nodemon |
| `npm run dev:all` | Both, side by side |
| `npm run build` | Production frontend build (`standalone`) |
| `npm run test:unit` | Frontend unit tests (vitest) |
| `npm test --prefix backend` | Backend tests (jest + mongodb-memory-server) |

## What changed from upstream

1. **Fresh history** — snapshot copy, not a fork, so no upstream commits.
2. **Secrets removed** — upstream tracked `backend/config.env` containing a real
   `JWT_SECRET`. It is deleted here and gitignored. If you deploy the upstream
   repo instead, rotate that secret first.
3. **`node_modules` untracked** — upstream committed ~2,100 dependency files;
   excluded here and restored with `npm ci`.
4. **Containerized** — added `Dockerfile` (frontend), `backend/Dockerfile`,
   `.dockerignore` files and `docker-compose.yml`.
5. **`output: 'standalone'`** enabled in `next.config.mjs` for slim images.
6. **Railway config dropped** (`railway.json`, its deployment guide) in favour of
   the Azure path above.

## Documentation

- [Documentation overview](docs/README.md)
- [Backend API](backend/README.md)
- [Demo guide](SALON_CRM_DEMO_GUIDE.md)
- [WhatsApp production guide](WHATSAPP_PRODUCTION_GUIDE.md)

## License

Proprietary — EaseMySalon. Copied here for personal learning use only.
