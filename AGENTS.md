# Shared Services

Base infrastructure that other deployments build on. This file is the policy for this repository.

## Scope

- Owns: the base services (PostgreSQL, Zitadel with its login UI, SeaweedFS, RabbitMQ, Jaeger), the network `infra-net`, the public edge (nginx + certbot), per-project provisioning, env templates, and the docs for them.
- Contains no business logic. A service only one consumer needs stays with that consumer.
- Knows nothing about its consumers. Their names, domains, upstreams, vhosts and settings never appear here, not even as examples. They register themselves by dropping a file in `projects/` and `edge/vhosts.d/` (git-ignored apart from templates). Their own repositories keep those files and the docs for them.
- Does not depend on any consumer. Consumers depend on it, never the other way round.
- Change a shared service only when the requested work needs it. Other projects run on it.

## General rules

- Write all technical text in English. Use `-`, never the em dash.
- Never commit secrets, keys, tokens, or real connection strings.
- Comment only a decision, constraint, or workaround that the file cannot show.
- Folder and file names use lowercase `kebab-case`, with no spaces. Names a tool requires keep their form (`README.md`, `AGENTS.md`, `compose.yml`, `.env*`, leading-dot names).
- Shell scripts are small and POSIX-compatible, start with `set -eu`, and never report success after a failed step.
- Line endings are LF (`*.sh` is forced to LF in `.gitattributes`).

## Structure

```
compose.yml        lists the service files (the only place that does)
compose.dev.yml    development overlay: ports on 127.0.0.1, pgAdmin
services/          one Compose file per service, plus _defaults.yml and network.yml
projects/          <id>.env per registered consumer (not versioned), generic example.env.example
provision/         scripts that create each project's own credentials
edge/              public nginx and certbot: compose.yml, templates/ (this stack's own vhosts), vhosts.d/ (dropped in), snippets/
scripts/           operations (backup)
```

- One Compose file per service in `services/`. A service extends `services/_defaults.yml` (log rotation, `no-new-privileges`, restart policy, `infra-net`) and adds only what is its own. Adding or dropping a service is one line in `compose.yml`.
- The base `compose.yml` is the production shape: no published ports, no domains, no dev tools. `compose.dev.yml` is the only place that publishes ports.
- Do not set `name:` on the stack: the project name comes from the folder and names the volumes. Changing it orphans the data.
- Registering a consumer edits nothing here: its deployment adds `projects/<id>.env` (and a vhost in `edge/vhosts.d/` for a public hostname). `<id>` is lowercase letters and digits; it becomes the Postgres role and `<id>_db`, the RabbitMQ user and vhost, and the Zitadel service account.
- `provision` and the SeaweedFS S3 config read `projects/*.env` through `provision/lib.sh`. Keep the `KEY=VALUE` format: no quotes, empty value means "no such service for this project".
- `edge/templates/` holds only this stack's own vhosts (identity, object storage) and nginx common settings, rendered with `ZITADEL_EXTERNAL_DOMAIN`, `S3_EXTERNAL_DOMAIN` and `EDGE_CERT_NAME`. No domain is hard-coded. Administrative routes (Zitadel console and management) are allow-listed with `edge/snippets/admin-allow.conf`, which dropped-in vhosts may include. Sign-in routes are rate limited.

## Infrastructure rules

### Isolation

- Each project gets its own credentials on each shared service, limited to its own resources. Admin credentials stay in this stack and are never copied to a project's env file.
- Provisioning is idempotent: safe on every `up` and after a volume reset. A consumer never touches another consumer's resources.

### Images

- Pin every image to a version, never `latest`. Services that belong together use the same version, changed in the same commit (Zitadel and its login UI).
- Pin to the version the volumes were written with. Never downgrade a stateful service. Bump one major at a time.
- Use trusted official images. Update them on purpose.

### Network and ports

- Containers talk by DNS name. Name them `infra-<service>` / `edge-<service>` and name every network. This stack creates `infra-net`; consumers declare it `external: true`.
- Publish a host port only when needed. In development bind to loopback (`127.0.0.1`, via `DEV_BIND_ADDRESS`). Production publishes only the edge ports 80 and 443.
- Never expose databases, brokers, internal APIs, or admin tools. Use HTTPS at public boundaries. Never turn off auth or TLS to simplify a deploy.
- The SeaweedFS filer has no authentication and is reachable by every container on `infra-net`. Only trusted containers join it. Do not hide this: keep it documented until the filer is protected.

### Configuration and secrets

- Secrets come only from git-ignored files (`.env`, `.env.prod`, `projects/*.env`). Commit a `*.example` template with placeholders (`CHANGE_ME`).
- No credentials in source, image layers, command output, or logs. No insecure production fallback for a required secret.
- Generate secrets as hex (`openssl rand -hex 24`). Other characters can break connection strings and interpolation. The Zitadel masterkey is exactly 32 characters.
- No duplicate or unused variables. Keep external contracts (network and container names) until their consumers agree to change them.

### Data

- Data that must survive recreation lives in named volumes. Keep Development and Production data apart.
- Never remove volumes in a normal update, restart, or shutdown. Never run destructive data operations automatically.
- Document backup, restore, and what wiping each volume does. `scripts/backup.sh` covers Postgres and the SeaweedFS and RabbitMQ volumes. The Zitadel masterkey is kept apart from backups.
- Run-time state (`zitadel/.output/` tokens, `edge/certbot/` certificates) is not versioned.

### Operations

- Every long-running service has a health check. Dependents wait for `service_healthy` inside the stack.
- Log rotation (`json-file`, `max-size`, `max-file`) and `no-new-privileges` come from `_defaults.yml`. Services that need more memory limits set them.
- Restart policy: `unless-stopped` for services, `"no"` for one-shot jobs. Run as non-root when the image allows. Do not rely on manual edits in a running container.
- Prefer mature, simple tools. Add a service or custom automation only for a real need.

## Verification

- Before finishing, run `docker compose config -q` for development (`--env-file .env.example -f compose.yml -f compose.dev.yml --profile tools`), production (`--env-file .env.prod.example -f compose.yml`), and `edge/compose.yml`.
- After editing `edge/`, run `nginx -t` against the rendered templates (the nginx image renders `templates/` on start; use sample domains and a temporary certificate).
- After editing `provision/`, run `sh -n` on the scripts and exercise `seaweedfs-s3-config.sh` with sample `projects/*.env` files made up for the test.
- Update the README when services, ports, env variables, the project file format, or the layout change.
- Never say a deployment works without checking images, health, and routing. Say which checks you could not run.

## Version control

- No AI `Co-Authored-By` trailer or other AI attribution in commits or pull requests.
- Commit messages in English, one logical change per commit.
- Never bypass hooks or verification (`--no-verify`).
- Touch only files that belong to the task. Leave unrelated modified files unstaged.
