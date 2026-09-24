#!/bin/sh
# Gives every consuming project its own credentials on the shared services,
# so no project holds another's data or the admin accounts:
#
#   Postgres  role <project>, owner of database <project>_db, which no
#             other role can connect to
#   RabbitMQ  user <project> with permissions only on vhost <project>
#   Zitadel   service account <project>-provisioner, PROJECT_OWNER of the
#             project's own Zitadel project only; its PAT is written to
#             /output/<project>/zitadel.pat for that project's zitadel-init
#
# (S3 identities are rendered into SeaweedFS's own config when it starts, see
# seaweedfs-s3-config.sh.)
#
# Idempotent: runs on every `up`. A service is only provisioned for a project
# when its setting is non-empty (no MUSIFY_RABBITMQ_PASSWORD, no RabbitMQ
# user for Musify). Passwords are re-applied on every run, so changing one
# in the env file and running `up` again rotates it.
set -eu -o pipefail

apk add --no-cache curl jq >/dev/null

# Value of the <PROJECT>_<suffix> setting, empty when unset.
setting() { eval "printf '%s' \"\${$(echo "$1" | tr '[:lower:]' '[:upper:]')_$2:-}\""; }

# --- Postgres ----------------------------------------------------------------
export PGHOST=postgres PGUSER="$POSTGRES_USER" PGPASSWORD="$POSTGRES_PASSWORD"

# By default every role may connect to every database (PUBLIC has CONNECT),
# including `zitadel` and `postgres`. Only the owner, roles granted it
# explicitly (Zitadel's own user on `zitadel`) and the superuser keep it.
lock_down_postgres() {
  psql -q -v ON_ERROR_STOP=1 -d postgres <<'SQL'
SELECT format('REVOKE CONNECT, TEMPORARY ON DATABASE %I FROM PUBLIC', datname)
FROM pg_database WHERE NOT datistemplate \gexec
SQL
  echo "  postgres: no database open to PUBLIC"
}

provision_postgres() {
  local project=$1 password=$2 db="$1_db"
  psql -q -v ON_ERROR_STOP=1 -d postgres -v role="$project" -v pw="$password" -v db="$db" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'role')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role') \gexec
ALTER ROLE :"role" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'pw';
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'role')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
ALTER DATABASE :"db" OWNER TO :"role";
REVOKE CONNECT, TEMPORARY ON DATABASE :"db" FROM PUBLIC;
SQL

  # A database from before this (created by the superuser, as were the
  # tables its migrations made) is handed over: the project's migrations
  # have to own what they alter.
  psql -q -v ON_ERROR_STOP=1 -d "$db" -v role="$project" <<'SQL' >/dev/null
SELECT set_config('provision.role', :'role', false);
DO $$
DECLARE
  target text := current_setting('provision.role');
  r record;
BEGIN
  FOR r IN
    SELECT n.nspname FROM pg_namespace n
    WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
      AND pg_get_userbyid(n.nspowner) NOT IN (target, 'pg_database_owner')
      AND NOT EXISTS (SELECT FROM pg_depend d WHERE d.classid = 'pg_namespace'::regclass AND d.objid = n.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('ALTER SCHEMA %I OWNER TO %I', r.nspname, target);
  END LOOP;

  -- Indexes and the sequences behind serial/identity columns follow their
  -- table; extension members stay with the extension.
  FOR r IN
    SELECT c.oid::regclass AS obj, c.relkind FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
      AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
      AND pg_get_userbyid(c.relowner) <> target
      AND NOT EXISTS (SELECT FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype IN ('a', 'i', 'e'))
  LOOP
    EXECUTE format('ALTER %s %s OWNER TO %I',
      CASE r.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW'
                     WHEN 'S' THEN 'SEQUENCE' WHEN 'f' THEN 'FOREIGN TABLE' ELSE 'TABLE' END,
      r.obj, target);
  END LOOP;

  -- Enums, domains, composite and range types (not a table's row type nor
  -- array types, which follow their element type).
  FOR r IN
    SELECT t.oid::regtype AS obj, t.typtype FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
      AND t.typtype IN ('e', 'd', 'c', 'r', 'm') AND t.typelem = 0
      AND (t.typrelid = 0 OR (SELECT relkind FROM pg_class WHERE oid = t.typrelid) = 'c')
      AND pg_get_userbyid(t.typowner) <> target
      AND NOT EXISTS (SELECT FROM pg_depend d WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype IN ('i', 'e'))
  LOOP
    EXECUTE format('ALTER %s %s OWNER TO %I', CASE r.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END, r.obj, target);
  END LOOP;

  FOR r IN
    SELECT p.oid::regprocedure AS obj FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
      AND pg_get_userbyid(p.proowner) <> target
      AND NOT EXISTS (SELECT FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('ALTER ROUTINE %s OWNER TO %I', r.obj, target);
  END LOOP;
END $$;
SQL
  echo "  postgres: role $project owns database $db"
}

# --- RabbitMQ ----------------------------------------------------------------
rabbitmq_put() {
  curl -fsS -o /dev/null -X PUT "http://rabbitmq:15672/api$1" \
    -u "$RABBITMQ_DEFAULT_USER:$RABBITMQ_DEFAULT_PASS" \
    -H "Content-Type: application/json" --data-raw "$2"
}

provision_rabbitmq() {
  local project=$1 password=$2
  rabbitmq_put "/vhosts/$project" '{}'
  rabbitmq_put "/users/$project" "$(jq -n --arg pw "$password" '{password: $pw, tags: ""}')"
  rabbitmq_put "/permissions/$project/$project" '{"configure": ".*", "write": ".*", "read": ".*"}'
  echo "  rabbitmq: user $project, only on vhost $project"
}

# --- Zitadel -----------------------------------------------------------------
# zitadel <token> <method> <path> [body]: prints the response body; on a
# non-2xx answer also reports it on stderr and returns non-zero. It calls
# Zitadel on infra-net, so it presents the public Host/scheme for Zitadel to
# find the instance (same as zitadel-login).
zitadel() {
  local response code
  response=$(curl -sS -w '\n%{http_code}' -X "$2" "http://zitadel:8080$3" \
    -H "Authorization: Bearer $1" -H "Content-Type: application/json" \
    -H "Host: $ZITADEL_EXTERNAL_DOMAIN" -H "X-Forwarded-Proto: $ZITADEL_PUBLIC_SCHEME" \
    ${4+--data-raw "$4"})
  code=$(printf '%s\n' "$response" | tail -n1)
  response=$(printf '%s\n' "$response" | sed '$d')
  printf '%s\n' "$response"
  case "$code" in
    2??) return 0 ;;
    *) printf 'zitadel: %s %s -> %s %s\n' "$2" "$3" "$code" "$response" >&2; return 1 ;;
  esac
}

# Stops the run when a lookup or creation didn't produce a value.
need() { [ -n "$2" ] && [ "$2" != null ] || { echo "zitadel: got no $1" >&2; exit 1; }; }

provision_zitadel() {
  local project=$1 zitadel_project=$2 username="$1-provisioner"
  local project_id user_id member_roles pat_file token state

  project_id=$(zitadel "$ADMIN_PAT" POST /management/v1/projects/_search \
    "$(jq -n --arg n "$zitadel_project" '{queries: [{nameQuery: {name: $n, method: "TEXT_QUERY_METHOD_EQUALS"}}]}')" \
    | jq -r '.result // [] | first | .id // empty')
  if [ -z "$project_id" ]; then
    project_id=$(zitadel "$ADMIN_PAT" POST /management/v1/projects "$(jq -n --arg n "$zitadel_project" '{name: $n}')" | jq -r .id)
  fi
  need "project id for $zitadel_project" "$project_id"

  user_id=$(zitadel "$ADMIN_PAT" POST /management/v1/users/_search \
    "$(jq -n --arg u "$username" '{queries: [{userNameQuery: {userName: $u, method: "TEXT_QUERY_METHOD_EQUALS"}}]}')" \
    | jq -r '.result // [] | first | .id // empty')
  if [ -z "$user_id" ]; then
    user_id=$(zitadel "$ADMIN_PAT" POST /management/v1/users/machine \
      "$(jq -n --arg u "$username" --arg p "$zitadel_project" \
        '{userName: $u, name: ($p + " provisioner"), description: ("zitadel-init of " + $p + ": manages that project only"), accessTokenType: "ACCESS_TOKEN_TYPE_BEARER"}')" \
      | jq -r .userId)
  fi
  need "user id for $username" "$user_id"

  # Owner of this one project (its apps, roles and grants) and nothing else.
  member_roles=$(zitadel "$ADMIN_PAT" POST "/management/v1/projects/$project_id/members/_search" \
    "$(jq -n --arg u "$user_id" '{queries: [{userIdQuery: {userId: $u}}]}')" \
    | jq -c '.result // [] | first | .roles // empty')
  if [ -z "$member_roles" ]; then
    zitadel "$ADMIN_PAT" POST "/management/v1/projects/$project_id/members" \
      "$(jq -n --arg u "$user_id" '{userId: $u, roles: ["PROJECT_OWNER"]}')" >/dev/null
  elif [ "$member_roles" != '["PROJECT_OWNER"]' ]; then
    zitadel "$ADMIN_PAT" PUT "/management/v1/projects/$project_id/members/$user_id" '{"roles": ["PROJECT_OWNER"]}' >/dev/null
  fi

  # Keep a PAT that still works. A new one (they can't be read back) is only
  # issued when there is none, or it was revoked or lost with a volume reset.
  pat_file="/output/$project/zitadel.pat"
  mkdir -p "/output/$project"
  chmod 700 "/output/$project"
  if [ -s "$pat_file" ] \
    && zitadel "$(tr -d '\r\n' <"$pat_file")" GET /auth/v1/users/me 2>/dev/null \
      | jq -e --arg u "$username" '.user.userName == $u' >/dev/null 2>&1; then
    state="kept"
  else
    token=$(zitadel "$ADMIN_PAT" POST "/management/v1/users/$user_id/pats" '{"expirationDate": "2099-01-01T00:00:00Z"}' | jq -r .token)
    need "PAT for $username" "$token"
    (umask 077 && printf '%s\n' "$token" >"$pat_file.tmp")
    mv "$pat_file.tmp" "$pat_file"
    state="issued"
  fi
  echo "  zitadel: $username owns project \"$zitadel_project\", PAT $state"
}

# -----------------------------------------------------------------------------
echo "==> waiting for Zitadel's admin PAT"
deadline=$(( $(date +%s) + 180 ))
until [ -s /output/admin-sa.pat ]; do
  [ "$(date +%s)" -lt "$deadline" ] || { echo "no /output/admin-sa.pat; check 'docker logs infra-zitadel'" >&2; exit 1; }
  sleep 3
done
ADMIN_PAT=$(tr -d '\r\n' </output/admin-sa.pat)

echo "==> shared"
lock_down_postgres

for project in $PROJECTS; do
  echo "==> $project"
  value=$(setting "$project" DB_PASSWORD)
  [ -z "$value" ] || provision_postgres "$project" "$value"
  value=$(setting "$project" RABBITMQ_PASSWORD)
  [ -z "$value" ] || provision_rabbitmq "$project" "$value"
  value=$(setting "$project" ZITADEL_PROJECT)
  [ -z "$value" ] || provision_zitadel "$project" "$value"
done
echo "==> done"
