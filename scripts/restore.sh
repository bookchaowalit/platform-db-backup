#!/usr/bin/env bash
# Restore one backup into a database. Run this from a disposable environment that holds the age
# private key; never point it at production without a written restore decision.
#
# Usage: restore.sh <object-path-in-bucket> <target-database-url>
#   e.g. restore.sh daily/habits/2026-10-18T0200.dump.age "$SCRATCH_DATABASE_URL"
# Environment: AGE_IDENTITY_FILE (path to the age private key), BACKUP_BUCKET, RCLONE_CONFIG_R2_*
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <object-path> <target-database-url>" >&2
  exit 2
fi
object="$1"
target_url="$2"
: "${AGE_IDENTITY_FILE:?set AGE_IDENTITY_FILE to the age private key file}"
: "${BACKUP_BUCKET:?set BACKUP_BUCKET}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

rclone copyto --s3-no-check-bucket "r2:$BACKUP_BUCKET/$object" "$work/backup.age"
age --decrypt --identity "$AGE_IDENTITY_FILE" --output "$work/backup" "$work/backup.age"

case "$object" in
  *.dump.age)
    # Render the whole archive to SQL first: this reads every data block, so a damaged archive
    # fails here, before anything in the target database changes. The PG18 client emits
    # `SET transaction_timeout`, which servers older than 17 reject, so drop that one line and
    # apply the script in a single transaction that stops on the first error.
    pg_restore --no-owner --no-privileges --clean --if-exists --file="$work/restore.sql" "$work/backup"
    strip_pg_preamble_setting "$work/restore.sql"
    # Row-level security policies name roles that live outside the dump; create missing ones.
    ensure_policy_roles "$work/restore.sql" "$target_url"
    psql --dbname="$target_url" --no-psqlrc --set ON_ERROR_STOP=1 --single-transaction \
      --quiet --file="$work/restore.sql"
    ;;
  *.sql.gz.age)
    gzip -t "$work/backup"
    parse_mysql_url "$target_url" || { echo "invalid mysql:// URL" >&2; exit 2; }
    gunzip -c "$work/backup" \
      | MYSQL_PWD="$MYSQL_URL_PASSWORD" mysql --host="$MYSQL_URL_HOST" --port="$MYSQL_URL_PORT" \
        --user="$MYSQL_URL_USER" "$MYSQL_URL_DATABASE"
    ;;
  *)
    echo "unknown backup type: $object" >&2
    exit 2
    ;;
esac
echo "restored $object"
