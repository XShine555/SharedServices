# Registering a consumer

VPS Services knows nothing about who uses it. A consumer registers itself by
adding a file; nothing in this repository is edited or versioned for it.

## The registration file

`projects/<id>.env` (see `projects/example.env.example`). The id is lowercase
letters and digits; it becomes the Postgres role and `<id>_db`, the RabbitMQ
user and vhost, and the Zitadel service account.

| Key | Gives the consumer |
|---|---|
| `DB_PASSWORD` | A Postgres role and its own database, which no other role can connect to |
| `RABBITMQ_PASSWORD` | A RabbitMQ user with permissions only on its own vhost |
| `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_BUCKET` | An S3 identity limited to its bucket (it may create it) |
| `ZITADEL_PROJECT` | A Zitadel project with a service account that owns only that project; its PAT is written to `zitadel/.output/<id>/zitadel.pat` |

Format: `KEY=VALUE`, no quotes. An empty value means the consumer does not get
that service. S3 keys use only `A-Z a-z 0-9 _ + / = . -` (hex from
`openssl rand -hex 24` is fine).

## Applying it

Run `up` again: `provision` is idempotent and re-applies every file on each
run, so changing a password in the file and running `up` rotates it. The
SeaweedFS identities are rendered when the container starts, so restart
`seaweedfs` after adding or changing S3 keys.

The consumer's own deployment then uses its credentials. It never gets the
admin accounts of this stack.

## Public hostnames

A consumer that needs one drops its own nginx vhost into `edge/vhosts.d/`. See
[edge.md](edge.md).
