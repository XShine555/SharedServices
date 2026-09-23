# Infrastructure

The technology services shared across projects (currently Musify, Ping and
docker-manager, each its own git repository): PostgreSQL, Zitadel (OIDC),
SeaweedFS (S3-compatible storage), RabbitMQ and Jaeger. None of these have
any business logic of their own, so instead of each project running (and
provisioning, and keeping in sync) its own copy, they run once, here.

This repo doesn't assume anything about where the other projects are
checked out. Each one just needs a local path to this repo's checkout (see
"The Zitadel admin PAT" below), which you set once in that project's own
`.env`.

Each project keeps its own independent, fast `docker compose up` for the
things that actually are its own: API/worker/gateway containers, database
migrations, its own OIDC apps and storage bucket. Those get created against
the shared Zitadel/SeaweedFS below by the project's own `zitadel-init` and
`seaweedfs-init` one-shot jobs (see e.g. `Musify/MusifyM/deploy/compose.yml`).
A project's dev stack only needs this one already running; nothing here
needs to know a consuming project exists.

## What's here vs. what stays in each project

| Here (shared) | Stays in each project |
|---|---|
| PostgreSQL (one instance, one database per project) | The project's own EF Core migrations, connection pooling config |
| Zitadel (OIDC provider) | The project's own OIDC app registration (`zitadel-init`), JWT validation config |
| SeaweedFS (S3 storage) | The project's own bucket (`seaweedfs-init`), key layout |
| RabbitMQ (broker) | The project's own exchanges/queues/consumers |
| Jaeger (OTLP collector + UI) | The project's own instrumentation |
| (not shared) | LiveKit (Ping only, a single-project SFU with its own port range) |

## Running it

```bash
cp .env.example .env
docker compose -f compose.yml -f compose.dev.yml up -d
```

That starts Postgres, Zitadel, SeaweedFS, RabbitMQ and Jaeger, with their
ports published to `localhost`. Add `--profile tools` to also start pgAdmin.

In production, the base `compose.yml` file **is** the production shape
already. There are no published ports, and everything is reachable only on
the internal `infra-net` network, so no overlay is needed:

```bash
cp .env.prod.example .env.prod
# fill in real values, then: chmod 600 .env.prod
docker compose --env-file .env.prod -f compose.yml up -d
```

A consuming project's own production compose joins `infra-net` as an
external network to reach `postgres`, `zitadel`, `seaweedfs`, `rabbitmq` and
`jaeger` by container name (see Musify's `deploy/compose.prod.yml`).

### Ports (development)

| Service | Port | Notes |
|---|---|---|
| PostgreSQL | `5432` | one instance, one database per project |
| Zitadel | `8080` | OIDC/OAuth2, console at `/ui/console` |
| SeaweedFS | `8333` / `8888` / `9333` | S3 API / filer / master |
| RabbitMQ | `5672` / `15672` | AMQP / management UI |
| Jaeger | `16686` / `4317` / `4318` | UI / OTLP gRPC / OTLP HTTP |
| pgAdmin (`--profile tools`) | `5050` | Postgres UI |

A consuming project reaches all of these at `host.docker.internal:<port>`
from inside its own containers. That's the same address the browser and the
host use, so it stays valid whichever way that project's own apps are
running (in Docker or from the IDE). No shared Docker network is needed in
development, which is what keeps every project's own `up` independent and
fast, with this stack as the only prerequisite.

### Shared secrets

`POSTGRES_USER`/`POSTGRES_PASSWORD`, `S3_ACCESS_KEY`/`S3_SECRET_KEY`,
`RABBITMQ_DEFAULT_USER`/`RABBITMQ_DEFAULT_PASS` and `PUBLIC_AUTH_URL` (i.e.
`http://host.docker.internal:${ZITADEL_EXTERNAL_PORT}` in dev) are the values
every consuming project's own `.env.example` copies and documents as "must
match this repo's `.env`". This file is the source of truth for them.

### The Zitadel admin PAT

`zitadel-init` (in the compose file of whichever project runs it first)
writes a service-account personal access token to `zitadel/.output/admin-sa.pat`
on first init. Every consuming project mounts that same folder read-only, via
its own `ZITADEL_ADMIN_PAT_DIR` setting, to call the Zitadel management API
and create its own project/apps.

That setting has no universally correct value. It's a path (relative or
absolute) to wherever *you* cloned this repo on your machine, from the
consuming project's `deploy/` folder. Each project's `.env.example` ships
with an example value that assumes these repos happen to sit as sibling
folders. If yours don't, change it. Not versioned, and regenerated whenever
the Zitadel volume is reset.

## The public edge

`edge/compose.yml` is the only thing that publishes host ports 80/443: one
nginx that terminates TLS for every project's domains (Gitea, Musify, ...)
and proxies to their containers by name, plus a certbot container that
renews the Let's Encrypt certificates (webroot) and lets nginx reload them
every 6 hours. It joins `infra-net` and the `gitea_gitea` network (both
external, created by the stacks that own them).

```bash
docker compose -f edge/compose.yml up -d
```

- **Vhosts** live in `edge/conf.d/` (one file per project; `00-common.conf`
  has the shared resolver). Every upstream is a `set $upstream ...`, resolved
  per request, so a project's stack being down never stops the edge from
  starting. Shared bits are in `edge/snippets/`. Check a change with
  `docker exec edge-nginx nginx -t`, then `docker exec edge-nginx nginx -s reload`.
- **Certificates** are state, not versioned (`edge/certbot/`). To issue one
  for new hostnames (their DNS has to already point at the host):

  ```bash
  docker compose -f edge/compose.yml run --rm --entrypoint certbot certbot     certonly --webroot -w /var/www/certbot -d host1.example.com -d host2.example.com     --non-interactive --agree-tos -m you@example.com
  ```

  Then add the `server` blocks pointing at
  `/etc/letsencrypt/live/<first -d name>/`.

## Resetting

```bash
docker compose -f compose.yml -f compose.dev.yml down          # stop, keep data
docker compose -f compose.yml -f compose.dev.yml down -v       # stop, wipe volumes
```

Wiping the volumes resets Zitadel (all projects/apps/users) and SeaweedFS
(all buckets). Every consuming project's own `zitadel-init`/`seaweedfs-init`
re-creates its piece on the next `up`, since both are idempotent.

## Layout

```
Infrastructure/
├─ compose.yml            # postgres, zitadel, seaweedfs, rabbitmq, jaeger: the prod shape
├─ edge/                  # shared public nginx + certbot (prod only): compose.yml, conf.d/, snippets/
├─ compose.dev.yml        # dev overlay: publishes ports, adds pgAdmin
├─ .env.example / .env.prod.example
├─ postgres-init/         # creates the per-project application databases
└─ zitadel/.output/       # PAT written by Zitadel on init (not versioned)
```
