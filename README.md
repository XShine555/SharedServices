# Shared Services

Infrastructure that every project (Musify, Ping, docker-manager, ...) shares,
so none of them runs its own copy.

## What it contains

| Service | Does | Dev port |
|---|---|---|
| PostgreSQL | One database and one role per project | `5432` |
| Zitadel (+ login UI) | OIDC sign-in and identity | `8080` / `3900` |
| SeaweedFS | S3 object storage, one bucket per project | `8333` |
| RabbitMQ | Message broker, one vhost per project | `5672` / `15672` |
| Jaeger | Tracing (OpenTelemetry) | `16686` / `4317` |
| `provision` | One-Shot job that creates each project's own credentials | none |
| `edge/` | Public nginx + Let's Encrypt for every project's domains (production) | 80 / 443 |

Projects never get the admin accounts: each one only sees its own database,
vhost, bucket and Zitadel project.

## Run it

```sh
cp .env.example .env
cp projects/musify.env.example projects/musify.env
docker compose -f compose.yml -f compose.dev.yml up -d
```

Development publishes the ports above on `127.0.0.1`. Production publishes
none; projects join the `infra-net` network instead:

```sh
cp .env.prod.example .env.prod # replace every CHANGE_ME, chmod 600
docker compose --env-file .env.prod -f compose.yml up -d
docker compose -f edge/compose.yml up -d # public TLS edge
```

## Add a project

Create `projects/<id>.env` from one of the `*.env.example` files (the id is
lowercase letters and digits) and run `up` again. Nothing else to edit. For a
public domain, add `edge/conf.d/<id>.conf`.

## Add or remove a service

Each service is one file in `services/`, listed in `compose.yml`. Copy a
small one (`services/jaeger.yml`), keep its `extends:` block, and add the file
to the list.

## Layout

```
compose.yml        lists the service files
compose.dev.yml    development overlay: ports on 127.0.0.1, pgAdmin
services/          one file per service
projects/          one <id>.env per project (not versioned)
provision/         scripts that create each project's credentials
edge/              public nginx and certbot
scripts/backup.sh  Postgres dump and volume archives
.env.example, .env.prod.example
```

## Good to know

- Production: the Zitadel console, `/scalar` and `/openapi` only answer to
  the addresses in `edge/snippets/admin-allow.conf`. Add yours.
- Back up with `sh scripts/backup.sh`, and keep the Zitadel masterkey apart:
  without it the backup is unusable.
- The SeaweedFS filer (`8888`) has no authentication: any container on
  `infra-net` can reach every bucket through it. Only run trusted containers
  there.
