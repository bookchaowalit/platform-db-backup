#!/usr/bin/env bash
# Restore one backup into a database. Run this from a disposable environment that holds the age
# private key; never point it at production without a written restore decision.
#
# Usage: restore.sh <object-path-in-bucket> <target-database-url>
#   e.g. restore.sh daily/habits/2026-10-18T0200.dump.age "$SCRATCH_DATABASE_URL"
# Environment: AGE_IDENTITY_FILE (path to the age private key), BACKUP_BUCKET, RCLONE_CONFIG_R2_*
set -euo pipefail

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
    pg_restore --list "$work/backup" >/dev/null
    pg_restore --no-owner --no-privileges --clean --if-exists --dbname="$target_url" "$work/backup"
    ;;
  *.sql.gz.age)
    rest="${target_url#mysql://}"
    creds="${rest%%@*}"
    hostpart="${rest#*@}"
    hostport="${hostpart%%/*}"
    database="${hostpart#*/}"
    database="${database%%\?*}"
    host="${hostport%%:*}"
    port="${hostport##*:}"
    [ "$port" = "$hostport" ] && port=3306
    gunzip -c "$work/backup" \
      | MYSQL_PWD="${creds#*:}" mysql --host="$host" --port="$port" --user="${creds%%:*}" "$database"
    ;;
  *)
    echo "unknown backup type: $object" >&2
    exit 2
    ;;
esac
echo "restored $object"
