# VPS Services

The base infrastructure of a VPS that other deployments build on, so none of
them runs its own copy. It only knows itself: it does not name or depend on
whoever uses it. Consumers register themselves with a file and get their own
credentials, never the admin accounts.

## What it contains

| Service | Does |
|---|---|
| PostgreSQL | One database and one role per consumer |
| Zitadel (+ login UI) | OIDC sign-in and identity |
| SeaweedFS | S3 object storage, one bucket per consumer |
| RabbitMQ | Message broker, one vhost per consumer |
| Jaeger | Tracing (OpenTelemetry) |
| `provision` | One-shot job that creates each registered consumer's credentials |
| `edge/` | Public nginx + Let's Encrypt (production) |

## Quick start

```sh
cp .env.example .env
docker compose -f compose.yml -f compose.dev.yml up -d
```

## Documentation

| Topic | File |
|---|---|
| Development, production, ports, resetting, adding a service | [docs/getting-started.md](docs/getting-started.md) |
| Registering a consumer (`projects/<id>.env`) | [docs/consumers.md](docs/consumers.md) |
| Public hostnames, TLS and admin allow-list | [docs/edge.md](docs/edge.md) |
| Backups, tokens, images, known limitations | [docs/operations.md](docs/operations.md) |
| Repository rules | [AGENTS.md](AGENTS.md) |
