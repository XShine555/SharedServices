#!/bin/sh
# Backs up the state of the shared stack to a directory (default ./backups/<utc stamp>):
#
#   postgres.sql.gz   every database (Zitadel, each project's) and role
#   seaweedfs.tgz     the object store volume (crash-consistent, not quiesced)
#   rabbitmq.tgz      the broker's definitions and queues volume
#
# The Zitadel masterkey is NOT in here: it lives in .env / .env.prod, keep that
# file somewhere safe (a password manager, not next to the backup): without it
# the Zitadel database cannot be decrypted.
#
# Run from this folder on the Docker host: sh scripts/backup.sh [target-dir]
# Restore: gunzip -c postgres.sql.gz | docker exec -i infra-postgres psql -U <superuser> -d postgres
set -eu

target=${1:-backups/$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$target"
umask 077

user=$(docker exec infra-postgres printenv POSTGRES_USER)
docker exec infra-postgres pg_dumpall -U "$user" | gzip >"$target/postgres.sql.gz"
[ -s "$target/postgres.sql.gz" ] || { echo "empty postgres dump" >&2; exit 1; }

volume_of() {
  docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$2\"}}{{.Name}}{{end}}{{end}}" "$1"
}

archive() {
  name=$(volume_of "$1" "$2")
  [ -n "$name" ] || { echo "no volume mounted at $2 in $1" >&2; exit 1; }
  docker run --rm -v "$name:/src:ro" -v "$PWD/$target:/dst" alpine:3.20 tar -czf "/dst/$3" -C /src .
}

archive infra-seaweedfs /data seaweedfs.tgz
archive infra-rabbitmq /var/lib/rabbitmq rabbitmq.tgz

echo "backup written to $target"
