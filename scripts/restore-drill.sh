#!/usr/bin/env bash
# Restore drill: for each target, fetch its newest daily backup and manifest from R2, restore it
# into a fresh scratch database, count the rows of every table and compare with the manifest
# taken at backup time. Scratch databases are dropped afterwards. Reports to the monitor as the
# `restore-drill` heartbeat and exits non-zero if any target fails.
#
# Environment:
#   DRILL_TARGETS          space-separated backup target names, e.g. "empire ev3 tma"
#   DRILL_PG_ADMIN_URL     postgres://… of a scratch PostgreSQL server (user may CREATE DATABASE)
#   DRILL_MYSQL_ADMIN_URL  mysql://… of a scratch MySQL server (user may CREATE DATABASE)
#   AGE_IDENTITY           age private key (content). Give this only to the drill service, and
#                          remove the service after the drill
#   BACKUP_BUCKET, RCLONE_CONFIG_R2_*, HEARTBEAT_URL, HEARTBEAT_TOKEN as for backup.sh
set -uo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

read -r -a targets <<<"${DRILL_TARGETS:-}"
if [ "${#targets[@]}" -eq 0 ] || [ -z "${AGE_IDENTITY:-}" ] || [ -z "${BACKUP_BUCKET:-}" ]; then
  log "FATAL DRILL_TARGETS, AGE_IDENTITY and BACKUP_BUCKET are required"
  exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
( umask 077 && printf '%s\n' "$AGE_IDENTITY" >"$work/identity" )

# Replace the database name in a URL (keeps credentials, host, port and query string).
with_database() {
  local url="$1" db="$2"
  local base="${url%%\?*}" query=""
  [ "$base" != "$url" ] && query="?${url#*\?}"
  printf '%s/%s%s' "${base%/*}" "$db" "$query"
}

failed=()
results=()

for target in "${targets[@]}"; do
  start=$(date +%s)
  scratch_db="drill_$(printf '%s' "$target" | tr -c '[:alnum:]\n' '_')"
  log "START $target"

  latest="$(rclone lsf --files-only "r2:$BACKUP_BUCKET/daily/$target/" 2>/dev/null \
    | grep -v '\.manifest\.tsv\.age$' | sort | tail -n 1)"
  if [ -z "$latest" ]; then
    log "FAIL $target: no daily backup found"
    failed+=("$target")
    continue
  fi
  manifest="${latest%.age}.manifest.tsv.age"
  if ! rclone copyto --s3-no-check-bucket "r2:$BACKUP_BUCKET/daily/$target/$latest" "$work/backup.age" \
    || ! rclone copyto --s3-no-check-bucket "r2:$BACKUP_BUCKET/daily/$target/$manifest" "$work/manifest.age" \
    || ! age --decrypt --identity "$work/identity" --output "$work/backup" "$work/backup.age" \
    || ! age --decrypt --identity "$work/identity" --output "$work/expected.tsv" "$work/manifest.age"; then
    log "FAIL $target: could not download or decrypt $latest and its manifest"
    failed+=("$target")
    continue
  fi

  restored=0
  case "$latest" in
    *.dump.age)
      admin="${DRILL_PG_ADMIN_URL:?DRILL_PG_ADMIN_URL is required for PostgreSQL targets}"
      scratch="$(with_database "$admin" "$scratch_db")"
      psql --dbname="$admin" --no-psqlrc --quiet --command="DROP DATABASE IF EXISTS $scratch_db" \
        && psql --dbname="$admin" --no-psqlrc --quiet --command="CREATE DATABASE $scratch_db" \
        && pg_restore --no-owner --no-privileges --file="$work/restore.sql" "$work/backup" \
        && sed -i '/^SET transaction_timeout = /d' "$work/restore.sql" \
        && psql --dbname="$scratch" --no-psqlrc --set ON_ERROR_STOP=1 --single-transaction --quiet \
             --file="$work/restore.sql" >/dev/null 2>"$work/restore.err" \
        && pg_table_counts "$scratch" >"$work/actual.tsv" \
        && restored=1
      psql --dbname="$admin" --no-psqlrc --quiet --command="DROP DATABASE IF EXISTS $scratch_db" || true
      ;;
    *.sql.gz.age)
      admin="${DRILL_MYSQL_ADMIN_URL:?DRILL_MYSQL_ADMIN_URL is required for MySQL targets}"
      parse_mysql_url "$admin" || { log "FAIL $target: invalid DRILL_MYSQL_ADMIN_URL"; failed+=("$target"); continue; }
      mysql_admin() { MYSQL_PWD="$MYSQL_URL_PASSWORD" mysql --host="$MYSQL_URL_HOST" --port="$MYSQL_URL_PORT" --user="$MYSQL_URL_USER" "$@"; }
      mysql_admin --execute="DROP DATABASE IF EXISTS \`$scratch_db\`; CREATE DATABASE \`$scratch_db\`" \
        && gunzip -c "$work/backup" | mysql_admin "$scratch_db" 2>"$work/restore.err" \
        && MYSQL_URL_DATABASE="$scratch_db" mysql_table_counts >"$work/actual.tsv" \
        && restored=1
      mysql_admin --execute="DROP DATABASE IF EXISTS \`$scratch_db\`" || true
      ;;
  esac
  seconds=$(( $(date +%s) - start ))

  if [ "$restored" != 1 ]; then
    log "FAIL $target: restore of $latest failed after ${seconds}s ($(classify_dump_error "$work/restore.err"))"
    failed+=("$target")
    continue
  fi

  tables="$(wc -l <"$work/expected.tsv")"
  rows="$(awk -F'\t' '{s += $2} END {print s + 0}' "$work/expected.tsv")"
  if diff -q "$work/expected.tsv" "$work/actual.tsv" >/dev/null; then
    log "OK $target $latest: $tables tables, $rows rows match the manifest (${seconds}s)"
    results+=("$target:$tables:$rows:${seconds}")
  else
    log "FAIL $target $latest: restored row counts differ from the manifest (${seconds}s):"
    diff "$work/expected.tsv" "$work/actual.tsv" | head -n 20
    failed+=("$target")
  fi
  rm -f "$work"/backup* "$work"/manifest.age "$work"/*.tsv "$work/restore.sql" "$work/restore.err"
done

ok=true
[ "${#failed[@]}" -gt 0 ] && ok=false
log "DONE ok=$ok passed=${#results[@]} failed=${#failed[@]}"

if [ -n "${HEARTBEAT_URL:-}" ]; then
  failed_json="$(printf '%s\n' "${failed[@]+"${failed[@]}"}" | jq -R . | jq -sc 'map(select(length > 0))')"
  passed_json="$(printf '%s\n' "${results[@]+"${results[@]}"}" | jq -R 'split(":") | select(length == 4)
    | {target: .[0], tables: (.[1] | tonumber), rows: (.[2] | tonumber), seconds: (.[3] | tonumber)}' | jq -sc .)"
  body="$(jq -nc --argjson ok "$ok" --argjson failed "$failed_json" --argjson passed "$passed_json" \
    '{job: "restore-drill", ok: $ok, passed: $passed, failed: $failed}')"
  curl --silent --show-error --fail --max-time 20 --retry 3 \
    -H "Authorization: Bearer ${HEARTBEAT_TOKEN:-}" -H 'Content-Type: application/json' \
    --data "$body" "$HEARTBEAT_URL" >/dev/null || log "WARN heartbeat failed"
fi

[ "$ok" = true ]
