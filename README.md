# sparkyfitness-railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/sparkyfitness-v161-or-myfitnesspal-alter?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

**Deploy on Railway:** [SparkyFitness template](https://railway.com/deploy/sparkyfitness-v161-or-myfitnesspal-alter?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

Railway wrapper images for [SparkyFitness](https://github.com/CodeWithCJ/SparkyFitness)
v1.6.1 — the self-hosted MyFitnessPal alternative (food, exercise, water, weight,
check-in photos, AI coach, MCP server).

| Image | Wraps | Purpose |
|---|---|---|
| `ghcr.io/bon5co/sparkyfitness-railway-server:latest` | `codewithcj/sparkyfitness_server:v1.6.1` | Seeds the deployer's admin account before the port is served, then runs with signup closed. Uploads and backups on the Railway volume. |
| `ghcr.io/bon5co/sparkyfitness-railway-web:latest` | `codewithcj/sparkyfitness:v1.6.1` | nginx frontend: auth rate limiter re-keyed per client, listener follows Railway's injected `$PORT`, backend reached over the private network. |

## Why these exist

**1. A stock deploy is claimable by a stranger.** Upstream ships
`SPARKY_FITNESS_DISABLE_SIGNUP` unset, and better-auth grants `role: admin` to the
first account created. Measured against `codewithcj/sparkyfitness_server:v1.6.1` with
no wrapper: an anonymous `POST /api/auth/sign-up/email` returned **200** with
`"role":"admin"`. Railway publishes the domain the moment the deploy goes healthy, so
the window is open from first boot. The server entrypoint here creates the deployer's
account on a throwaway listener bound before the real server starts, then re-execs with
signup disabled — anonymous signup then returns **400 "Signups are currently disabled
by the administrator."** while the generated password logs in **200**. Seeding is
idempotent: a redeploy sees the existing account and skips straight to start.

**2. The login rate limiter is one shared bucket behind Railway's edge.** Upstream keys
`limit_req_zone` on `$binary_remote_addr`, which on Railway is always an edge address.
`X-Forwarded-For` is `<client>, <edge>` and the edge hop rotates per request, so only
the first address is a stable per-client key. Measured with 30 requests from 30
distinct client addresses: stock returned **18 × 503**, this image **0**; and 30
requests from a single client address still return **18 × 503**, so the limit still
does its job.

**3. Uploads and backups are on the volume.** `SPARKY_FITNESS_CUSTOM_UPLOADS_DIRECTORY`
and `SPARKY_FITNESS_CUSTOM_BACKUP_DIRECTORY` are baked to `/data/uploads` and
`/data/backup`; profile pictures, exercise images and check-in photos otherwise live on
the ephemeral layer under `/app/SparkyFitnessServer/uploads`.

**4. The frontend follows `$PORT`.** Railway's HTTP healthcheck dials the injected port,
not the domain's target port, so the nginx listener is derived from `$PORT`.

## Layout

- `Dockerfile.server` / `railway-entrypoint-server.sh`
- `Dockerfile.web` / `railway-entrypoint-web.sh` / `nginx.conf` (upstream's v1.6.1
  template with the rate-limit key changed)
