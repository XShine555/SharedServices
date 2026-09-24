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

That starts Postgres, Zitadel (and its login UI), SeaweedFS, RabbitMQ and Jaeger, with their
ports published on `127.0.0.1` only (`DEV_BIND_ADDRESS`), so the dev
credentials aren't reachable from the LAN. Add `--profile tools` to also
start pgAdmin.

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
`jaeger` by name (see Musify's `deploy/compose.prod.yml`).

Every project on `infra-net` shares one DNS namespace, and Docker answers a
service name with *every* container that has it, round-robin. Two projects
each with a service called `api` would get each other's traffic. So anything
that crosses projects (the edge, or one project calling into this stack)
should use the unique `container_name` (`infra-postgres`, `musify-api`, ...),
never a generic service name.

### RabbitMQ and its hostname

RabbitMQ keeps its data under its node name, `rabbit@<hostname>`, so the
container has a fixed `hostname: rabbitmq`. Without it every recreated
container (an image update, an `.env` change) came up with a new hostname
and an empty broker. A deployment that ran before this was fixed has its
data under the old random name; carry the definitions (users, vhosts,
permissions, queues, exchanges) over when applying the change, ideally with
the queues drained, since queued messages aren't part of the export:

```bash
docker exec infra-rabbitmq rabbitmqctl export_definitions /var/lib/rabbitmq/defs.json
docker compose --env-file .env.prod -f compose.yml up -d rabbitmq
docker exec infra-rabbitmq rabbitmqctl import_definitions /var/lib/rabbitmq/defs.json
```

### Ports (development)

| Service | Port | Notes |
|---|---|---|
| PostgreSQL | `5432` | one instance, one database per project |
| Zitadel | `8080` | OIDC/OAuth2, console at `/ui/console` |
| Zitadel login | `3900` | Login V2 UI at `/ui/v2/login` (under `8080`'s hostname in prod) |
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

Zitadel itself writes a service-account personal access token to
`zitadel/.output/admin-sa.pat` when the instance is created. Every consuming project mounts that same folder read-only, via
its own `ZITADEL_ADMIN_PAT_DIR` setting, to call the Zitadel management API
and create its own project/apps.

That setting has no universally correct value. It's a path (relative or
absolute) to wherever *you* cloned this repo on your machine, from the
consuming project's `deploy/` folder. Each project's `.env.example` ships
with an example value that assumes these repos happen to sit as sibling
folders. If yours don't, change it. Not versioned, and regenerated whenever
the Zitadel volume is reset.

### The Zitadel login (Login V2)

Zitadel v4 serves its sign-in pages from a separate container,
`zitadel-login` (Next.js), under `/ui/v2/login`. Zitadel redirects every
login there, so it has to be running for anyone to sign in. It calls the
Zitadel API with its own service account (`login-client`), whose PAT Zitadel
writes on init to the `zitadel_bootstrap` volume, which only `zitadel-login`
mounts.

- **Dev**: no proxy, so the login has its own port (`ZITADEL_LOGIN_HOST_PORT`,
  `3900`) and `ZITADEL_LOGIN_BASE_URL` points the browser at it.
- **Prod**: the edge routes `/ui/v2/login` on Zitadel's hostname to
  `infra-zitadel-login`, and everything else to Zitadel.
- `zitadel` and `zitadel-login` are pinned to the same version; bump both
  together.

`ZITADEL_LOGIN_BASE_URL` and the `login-client` PAT are only applied when the
instance is created. On an instance created before `zitadel-login` existed:

1. In the console, create a service user `login-client`, give it the
   instance role **IAM Login Client**, and create a PAT for it.
2. Copy it into the volume and restart the login:

   ```bash
   docker cp login-client.pat infra-zitadel:/bootstrap/login-client.pat
   docker restart infra-zitadel-login
   ```

3. If the instance still uses the old login, set Login V2 as required with
   base URI `${ZITADEL_LOGIN_BASE_URL}/` in the instance's feature settings.

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
  starting. Upstreams use the target's `container_name` (see "Running it"
  above for why). Shared bits are in `edge/snippets/`. Check a change with
  `docker exec edge-nginx nginx -t`, then `docker exec edge-nginx nginx -s reload`.
- **Unknown hostnames** hit `01-default.conf`: port 80 closes the connection
  (ACME challenges still work), port 443 refuses the TLS handshake. Nothing
  reaches a project unless its vhost names the host.
- **TLS** settings (`snippets/tls.conf`) follow Mozilla's intermediate
  profile and send HSTS with a 1-day `max-age`. Raise it once every hostname
  is confirmed to work over https: browsers remember it, so a long value
  can't be taken back quickly.
- **Certificates** are state, not versioned (`edge/certbot/`). To issue one
  for new hostnames (their DNS has to already point at the host):

  ```bash
  docker compose -f edge/compose.yml run --rm --entrypoint certbot certbot \
    certonly --webroot -w /var/www/certbot -d host1.example.com -d host2.example.com \
    --non-interactive --agree-tos -m you@example.com
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
├─ compose.yml            # postgres, zitadel (+ login), seaweedfs, rabbitmq, jaeger: the prod shape
├─ edge/                  # shared public nginx + certbot (prod only): compose.yml, conf.d/, snippets/
├─ compose.dev.yml        # dev overlay: publishes ports, adds pgAdmin
├─ .env.example / .env.prod.example
├─ postgres-init/         # creates the per-project application databases
└─ zitadel/.output/       # PAT written by Zitadel on init (not versioned)
```
