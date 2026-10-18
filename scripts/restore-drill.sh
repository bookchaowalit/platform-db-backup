#!/usr/bin/env bash
# Restore drill: for each target, take its newest daily backup that has a manifest, restore it
# into a fresh scratch database, count the rows of every table and compare with the manifest
# written at backup time (same snapshot as the dump). Scratch databases are created with a unique
# name per run and always dropped, also on failure or interruption. Reports to the monitor as the
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

trap '' PIPE

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

read -r -a targets <<<"${DRILL_TARGETS:-}"
if [ "${#targets[@]}" -eq 0 ] || [ -z "${AGE_IDENTITY:-}" ] || [ -z "${BACKUP_BUCKET:-}" ]; then
  log "FATAL DRILL_TARGETS, AGE_IDENTITY and BACKUP_BUCKET are required"
  exit 2
fi

work="$(mktemp -d)"
run_id="$(date -u +%Y%m%d%H%M%S)$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
owned_pg=()     # scratch databases this run created; only these are ever dropped
owned_mysql=()
cleanup_failed=0

pg_admin() {
  psql --dbname="$DRILL_PG_ADMIN_URL" --no-psqlrc --quiet --set ON_ERROR_STOP=1 "$@" 2>>"$work/admin.err"
}
mysql_admin() {
  local MYSQL_URL_USER MYSQL_URL_PASSWORD MYSQL_URL_HOST MYSQL_URL_PORT MYSQL_URL_DATABASE
  parse_mysql_url "$DRILL_MYSQL_ADMIN_URL" || return 64
  MYSQL_PWD="$MYSQL_URL_PASSWORD" mysql --host="$MYSQL_URL_HOST" --port="$MYSQL_URL_PORT" \
    --user="$MYSQL_URL_USER" "$@" 2>>"$work/admin.err"
}

drop_owned() {
  local db
  for db in "${owned_pg[@]+"${owned_pg[@]}"}"; do
    pg_admin --command="DROP DATABASE IF EXISTS \"$db\"" || { cleanup_failed=1; log "ERROR could not drop scratch database $db"; }
  done
  for db in "${owned_mysql[@]+"${owned_mysql[@]}"}"; do
    mysql_admin --execute="DROP DATABASE IF EXISTS \`$db\`" || { cleanup_failed=1; log "ERROR could not drop scratch database $db"; }
  done
  owned_pg=()
  owned_mysql=()
}
trap 'drop_owned; rm -rf "$work"' EXIT
trap 'exit 130' INT TERM
( umask 077 && printf '%s\n' "$AGE_IDENTITY" >"$work/identity" )

failed=()
results=()
index=0

for target in "${targets[@]}"; do
  index=$((index + 1))
  start=$(date +%s)
  : >"$work/admin.err"
  : >"$work/restore.err"
  # Unique per run and per position; lowercase letters, digits and "_" only; at most 63 bytes.
  safe="$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '_' | cut -c1-30)"
  scratch_db="drill_${run_id}_${index}_${safe}"
  scratch_db="${scratch_db:0:63}"
  log "START $target"

  # Newest manifest first: a manifest is uploaded only after its dump, so its dump is complete.
  manifest="$(rclone lsf --files-only "r2:$BACKUP_BUCKET/daily/$target/" 2>/dev/null \
    | grep '\.manifest\.tsv\.age$' | sort | tail -n 1)"
  if [ -z "$manifest" ]; then
    log "FAIL $target: no daily backup with a manifest found"
    failed+=("$target")
    continue
  fi
  latest="${manifest%.manifest.tsv.age}.age"
  if ! rclone copyto --s3-no-check-bucket "r2:$BACKUP_BUCKET/daily/$target/$latest" "$work/backup.age" 2>/dev/null \
    || ! rclone copyto --s3-no-check-bucket "r2:$BACKUP_BUCKET/daily/$target/$manifest" "$work/manifest.age" 2>/dev/null \
    || ! age --decrypt --identity "$work/identity" --output "$work/backup" "$work/backup.age" \
    || ! age --decrypt --identity "$work/identity" --output "$work/expected.tsv" "$work/manifest.age" \
    || ! valid_manifest "$work/expected.tsv"; then
    log "FAIL $target: could not download, decrypt or read $latest and its manifest"
    failed+=("$target")
    continue
  fi

  restored=0
  case "$latest" in
    *.dump.age)
      if [ -z "${DRILL_PG_ADMIN_URL:-}" ]; then
        log "FAIL $target: DRILL_PG_ADMIN_URL is required for PostgreSQL targets"
        failed+=("$target")
        continue
      fi
      scratch="$(pg_url_with_database "$DRILL_PG_ADMIN_URL" "$scratch_db")"
      if pg_admin --command="CREATE DATABASE \"$scratch_db\""; then
        owned_pg+=("$scratch_db")
        pg_restore --no-owner --no-privileges --file="$work/restore.sql" "$work/backup" 2>>"$work/restore.err" \
          && strip_pg_preamble_setting "$work/restore.sql" \
          && psql --dbname="$scratch" --no-psqlrc --set ON_ERROR_STOP=1 --single-transaction --quiet \
               --file="$work/restore.sql" >/dev/null 2>>"$work/restore.err" \
          && pg_table_counts "$scratch" >"$work/actual.tsv" 2>>"$work/restore.err" \
          && valid_manifest "$work/actual.tsv" \
          && restored=1
      fi
      ;;
    *.sql.gz.age)
      if [ -z "${DRILL_MYSQL_ADMIN_URL:-}" ]; then
        log "FAIL $target: DRILL_MYSQL_ADMIN_URL is required for MySQL targets"
        failed+=("$target")
        continue
      fi
      if mysql_admin --execute="CREATE DATABASE \`$scratch_db\`"; then
        owned_mysql+=("$scratch_db")
        gzip -t "$work/backup" \
          && gunzip -c "$work/backup" | mysql_admin "$scratch_db" \
          && (
            parse_mysql_url "$DRILL_MYSQL_ADMIN_URL" && MYSQL_URL_DATABASE="$scratch_db" \
              MYSQL_COUNTS_OUT="$work/actual.tsv" mysql_table_counts
          ) 2>>"$work/restore.err" \
          && valid_manifest "$work/actual.tsv" \
          && restored=1
      fi
      ;;
  esac
  drop_owned
  seconds=$(( $(date +%s) - start ))

  if [ "$restored" != 1 ]; then
    cat "$work/admin.err" >>"$work/restore.err"
    log "FAIL $target: restore of $latest failed after ${seconds}s ($(classify_dump_error "$work/restore.err"))"
    failed+=("$target")
  else
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
  fi
  rm -f "$work"/backup* "$work"/manifest.age "$work"/*.tsv "$work/restore.sql"
done

if [ "$cleanup_failed" = 1 ]; then
  log "FAIL a scratch database could not be dropped; remove it by hand"
  failed+=("cleanup")
fi

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
    --data "$body" "$HEARTBEAT_URL" >/dev/null 2>&1 || log "WARN heartbeat failed"
fi

[ "$ok" = true ]
