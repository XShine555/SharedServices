#!/bin/sh
# Prints SeaweedFS's S3 identity config (JSON) from the environment:
#
#   infra      S3_ACCESS_KEY / S3_SECRET_KEY, admin on every bucket (for
#              operating the stack, not for projects)
#   <project>  <PROJECT>_S3_ACCESS_KEY / _SECRET_KEY, limited to the bucket
#              <PROJECT>_S3_BUCKET (it may create it, nothing else)
#
# A project without keys gets no identity. Runs in the SeaweedFS container on
# every start, so the credentials can't drift from the env file.
set -eu

upper() { echo "$1" | tr '[:lower:]' '[:upper:]'; }
setting() { eval "printf '%s' \"\${$(upper "$1")_$2:-}\""; }

# The values go into JSON as they are: keep them to characters that need no
# escaping (what `openssl rand -hex` / -base64 produce).
check() {
  case "$2" in
    '' | *[!A-Za-z0-9_+/=.-]*) echo "seaweedfs-s3-config: $1 must be non-empty and only use A-Z a-z 0-9 _ + / = . -" >&2; exit 1 ;;
  esac
}

identity() {
  printf '    {"name": "%s", "credentials": [{"accessKey": "%s", "secretKey": "%s"}], "actions": [%s]}' "$1" "$2" "$3" "$4"
}

# SeaweedFS refuses to start (and keeps restarting) on a repeated access key,
# e.g. two values left at CHANGE_ME: say which ones instead.
seen=" "
unique() {
  case "$seen" in
    *" $2 "*) echo "seaweedfs-s3-config: $1 repeats an access key already used above; every identity needs its own" >&2; exit 1 ;;
  esac
  seen="$seen$2 "
}

check S3_ACCESS_KEY "$S3_ACCESS_KEY"
unique S3_ACCESS_KEY "$S3_ACCESS_KEY"
check S3_SECRET_KEY "$S3_SECRET_KEY"
printf '{\n  "identities": [\n'
identity infra "$S3_ACCESS_KEY" "$S3_SECRET_KEY" '"Admin", "Read", "Write"'

for project in $PROJECTS; do
  access=$(setting "$project" S3_ACCESS_KEY)
  [ -n "$access" ] || continue
  secret=$(setting "$project" S3_SECRET_KEY)
  bucket=$(setting "$project" S3_BUCKET)
  prefix=$(upper "$project")
  check "${prefix}_S3_ACCESS_KEY" "$access"
  check "${prefix}_S3_SECRET_KEY" "$secret"
  check "${prefix}_S3_BUCKET" "$bucket"
  unique "${prefix}_S3_ACCESS_KEY" "$access"
  # Admin:<bucket> is what lets it create (and configure) that one bucket.
  printf ',\n'
  identity "$project" "$access" "$secret" \
    "\"Admin:$bucket\", \"Read:$bucket\", \"Write:$bucket\", \"List:$bucket\", \"Tagging:$bucket\""
  echo "seaweedfs-s3-config: $project -> bucket $bucket" >&2
done
printf '\n  ]\n}\n'
