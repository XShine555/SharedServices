# Getting started

## Requirements

Docker with Compose v2.20 or newer (the stack uses `include` and `extends`).

## Development

```sh
cp .env.example .env
docker compose -f compose.yml -f compose.dev.yml up -d
```

Ports are published on `127.0.0.1` (change `DEV_BIND_ADDRESS` in `.env` to
publish elsewhere):

| Service | Port | Notes |
|---|---|---|
| PostgreSQL | `5432` | one database and role per consumer |
| Zitadel | `8080` | OIDC; console at `/ui/console` |
| Zitadel login | `3900` | Login V2 UI at `/ui/v2/login` |
| SeaweedFS | `8333` / `8888` / `9333` | S3 API / filer / master |
| RabbitMQ | `5672` / `15672` | AMQP / management UI |
| Jaeger | `16686` / `4317` / `4318` | UI / OTLP gRPC / OTLP HTTP |
| pgAdmin (`--profile tools`) | `5050` | Postgres UI |

A consumer reaches them at `host.docker.internal:<port>`, the same address the
browser and the host use, so no shared Docker network is needed in development.

## Production

```sh
cp .env.prod.example .env.prod      # replace every CHANGE_ME, chmod 600
docker compose --env-file .env.prod -f compose.yml up -d
docker compose --env-file .env.prod -f edge/compose.yml up -d
```

Nothing publishes ports except the edge (80 and 443). Consumers join the
`infra-net` network. See [edge.md](edge.md) for the first certificate.

## Resetting

```sh
docker compose -f compose.yml -f compose.dev.yml down       # stop, keep data
docker compose -f compose.yml -f compose.dev.yml down -v    # stop, wipe volumes
```

Wiping the volumes resets Zitadel (every project, app and user) and
SeaweedFS (every bucket). Each consumer's own init jobs recreate their part on
the next `up`.

## Services

Each service is one file in `services/`, listed in `compose.yml`. To add one,
copy a small file such as `services/jaeger.yml`, keep its `extends:` block (log
rotation, `no-new-privileges`, restart policy and the network come from
`services/_defaults.yml`) and add the file to the list. To drop one, remove its
line.
