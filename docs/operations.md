# Operations

## Backups

`sh scripts/backup.sh [target-dir]` dumps Postgres (which holds all of
Zitadel's state) and archives the SeaweedFS and RabbitMQ volumes. Keep the
Zitadel masterkey apart from the backup: without it the dump cannot be used.
Test a restore before relying on it.

## Credentials and tokens

- Each consumer's service-account PAT expires after one year. `provision`
  issues a new one on the next `up` once the old one stops working, so run `up`
  at least yearly.
- The instance-admin PAT Zitadel creates on first start (`admin-sa.pat`) is for
  `provision` only. Consumers get their own under `zitadel/.output/<id>/`.
- Set `ZITADEL_ADMIN_PASSWORD_CHANGE_REQUIRED=true` (the production template
  does) so the first admin chooses a new password; enable MFA afterwards.

## Images

Images are pinned to the versions that were running when this was reviewed.
Bump them on purpose and one major at a time: a volume written by a newer
version may refuse to start on an older one. Zitadel and its login UI share one
version and change in the same commit. `provision` installs `curl` and `jq` at
start (`apk`), which needs outbound network on every `up`.

## Known limitation: the SeaweedFS filer

The filer (`8888`) has no authentication: any container on `infra-net` can read
and write every bucket through it, bypassing the S3 identities. Only run
trusted containers on `infra-net`. Fixing it changes the data path (a
path-restricted read-only proxy in front of the filer, or reading through S3)
and needs testing against a running stack.

## Layout

```
compose.yml        lists the service files
compose.dev.yml    development overlay: ports on 127.0.0.1, pgAdmin
services/          one file per service
projects/          <id>.env per registered consumer (not versioned)
provision/         scripts that create each consumer's credentials
edge/              public nginx and certbot (templates/, vhosts.d/, snippets/)
scripts/backup.sh  Postgres dump and volume archives
```

The Compose project name comes from the folder name and names the volumes:
renaming the folder of a running stack orphans its data.
