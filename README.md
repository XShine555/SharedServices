# Shared Services

Base infrastructure that other deployments build on, so none of them runs its
own copy. It only knows itself: it does not name or depend on whoever uses it.

## What it contains

| Service | Does | Dev port |
|---|---|---|
| PostgreSQL | One database and one role per consumer | `5432` |
| Zitadel (+ login UI) | OIDC sign-in and identity | `8080` / `3900` |
| SeaweedFS | S3 object storage, one bucket per consumer | `8333` |
| RabbitMQ | Message broker, one vhost per consumer | `5672` / `15672` |
| Jaeger | Tracing (OpenTelemetry) | `16686` / `4317` |
| `provision` | One-shot job that creates each registered consumer's own credentials | none |
| `edge/` | Public nginx + Let's Encrypt for this stack's hostnames and any vhost dropped in (production) | 80 / 443 |

Consumers never get the admin accounts: each one only sees its own database,
vhost, bucket and Zitadel project.

## Run it

```sh
cp .env.example .env
docker compose -f compose.yml -f compose.dev.yml up -d
```

Development publishes the ports above on `127.0.0.1`. Production publishes
none; consumers join the `infra-net` network instead:

```sh
cp .env.prod.example .env.prod      # replace every CHANGE_ME, chmod 600
docker compose --env-file .env.prod -f compose.yml up -d
docker compose --env-file .env.prod -f edge/compose.yml up -d   # public TLS edge
```

## Register a consumer

A consumer's own deployment adds `projects/<id>.env` (see
`projects/example.env.example`; the id is lowercase letters and digits) and
runs `up` again. Nothing here is edited or versioned for it. For a public
hostname it drops its own nginx vhost in `edge/vhosts.d/` and reloads
(`docker exec edge-nginx nginx -s reload`).

## Add or remove a service

Each service is one file in `services/`, listed in `compose.yml`. Copy a
small one (`services/jaeger.yml`), keep its `extends:` block, and add the file
to the list.

## Layout

```
compose.yml        lists the service files
compose.dev.yml    development overlay: ports on 127.0.0.1, pgAdmin
services/          one file per service
projects/          <id>.env per registered consumer (not versioned)
provision/         scripts that create each consumer's credentials
edge/              public nginx and certbot (templates/, vhosts.d/)
scripts/backup.sh  Postgres dump and volume archives
.env.example, .env.prod.example
```

## Good to know

- Production: the Zitadel console and management APIs only answer to the
  addresses in `edge/snippets/admin-allow.conf` (vhosts in `vhosts.d/` can
  include it too). Add yours.
- Back up with `sh scripts/backup.sh`, and keep the Zitadel masterkey apart:
  without it the backup is unusable.
- The SeaweedFS filer (`8888`) has no authentication: any container on
  `infra-net` can reach every bucket through it. Only run trusted containers
  there.
