# Shared by provision.sh and seaweedfs-s3-config.sh: finds the projects.
#
# A project is a file projects/<id>.env (mounted at /projects) with
# KEY=VALUE lines (no quotes, no spaces around =) such as DB_PASSWORD,
# RABBITMQ_PASSWORD, S3_ACCESS_KEY, S3_SECRET_KEY, S3_BUCKET, ZITADEL_PROJECT.
# <id> becomes the Postgres role, <id>_db, the RabbitMQ user and vhost and the
# Zitadel service account name, so it is lowercase letters and digits only.
# Sets PROJECT_IDS (space separated).

PROJECTS_DIR=${PROJECTS_DIR:-/projects}
PROJECT_IDS=""
for _file in "$PROJECTS_DIR"/*.env; do
  [ -f "$_file" ] || continue
  _id=$(basename "$_file" .env)
  case "$_id" in
    [a-z]*) ;;
    *) echo "projects/$_id.env: the file name must start with a lowercase letter" >&2; exit 1 ;;
  esac
  case "$_id" in
    *[!a-z0-9]*) echo "projects/$_id.env: the file name may only have lowercase letters and digits" >&2; exit 1 ;;
  esac
  PROJECT_IDS="$PROJECT_IDS $_id"
done

# setting <project> <KEY>: value from the project's file, empty when unset.
setting() {
  sed -n "s/^$2=//p" "$PROJECTS_DIR/$1.env" | tail -n 1 | tr -d '\r'
}
