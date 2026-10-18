#!/usr/bin/env bash
# Dump every database in BACKUP_TARGETS, encrypt each dump with age, upload it to R2 and report
# the result to the uptime monitor's heartbeat endpoint. One failed target never stops the rest;
# the job exits non-zero if any target failed.
#
# Required environment (see README.md for the full list):
#   BACKUP_TARGETS            space-separated target names, e.g. "habits tax ev3"
#   BACKUP_URL_<NAME>         connection URL per target (postgres:// or mysql://); NAME is the
#                             target name upper-cased with "-" replaced by "_"
#   AGE_RECIPIENT             age public key; the private key never lives on Railway
#   BACKUP_BUCKET             R2 bucket name
#   RCLONE_CONFIG_R2_*        rclone remote "r2" (type s3, provider Cloudflare)
# Optional:
#   HEARTBEAT_URL, HEARTBEAT_TOKEN   uptime monitor heartbeat endpoint
#   BACKUP_TZ                 timezone used for file names and the weekly/monthly copies
#                             (default Asia/Bangkok)
set -uo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

for var in AGE_RECIPIENT BACKUP_BUCKET; do
  if [ -z "${!var:-}" ]; then
    log "FATAL missing $var"
    exit 2
  fi
done
read -r -a targets <<<"${BACKUP_TARGETS:-}"
if [ "${#targets[@]}" -eq 0 ]; then
  log "FATAL BACKUP_TARGETS is empty"
  exit 2
fi

export TZ="${BACKUP_TZ:-Asia/Bangkok}"
stamp="$(date +%Y-%m-%dT%H%M)"
day_of_week="$(date +%u)"  # 7 = Sunday
day_of_month="$(date +%d)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failed=()
succeeded=0
total_bytes=0

dump_postgres() {
  local url="$1" out="$2"
  pg_dump --format=custom --compress=6 --no-owner --no-privileges --dbname="$url" --file="$out" \
    && pg_restore --file=/dev/null "$out" \
    && pg_table_counts "$url" >"$out.manifest.tsv"
  # pg_restore --file=/dev/null reads every data block, not just the table of contents. The
  # manifest (exact row count per table, taken right after the dump) lets a restore drill prove
  # the restored copy is complete; rows written between dump and count can make it differ slightly.
}

dump_mysql() {
  local url="$1" out="$2"
  parse_mysql_url "$url" || return 64
  MYSQL_PWD="$MYSQL_URL_PASSWORD" mysqldump --host="$MYSQL_URL_HOST" --port="$MYSQL_URL_PORT" \
    --user="$MYSQL_URL_USER" --single-transaction --routines --triggers --events --skip-lock-tables \
    "$MYSQL_URL_DATABASE" \
    | gzip -6 >"$out" \
    && gzip -t "$out" \
    && mysql_table_counts >"$out.manifest.tsv"
}

for target in "${targets[@]}"; do
  key="BACKUP_URL_$(printf '%s' "$target" | tr '[:lower:]-' '[:upper:]_')"
  url="${!key:-}"
  if [ -z "$url" ]; then
    log "FAIL $target: $key is not set"
    failed+=("$target")
    continue
  fi

  case "$url" in
    postgres://* | postgresql://*) ext="dump"; dumper=dump_postgres ;;
    mysql://*) ext="sql.gz"; dumper=dump_mysql ;;
    *)
      log "FAIL $target: unsupported URL scheme"
      failed+=("$target")
      continue
      ;;
  esac

  raw="$work/$target.$ext"
  enc="$raw.age"
  name="$target/$stamp.$ext.age"
  log "START $target"

  "$dumper" "$url" "$raw" 2>"$work/$target.err"
  status=$?
  if [ "$status" -ne 0 ]; then
    # Never log the raw client error: libpq and mysql can echo parts of the connection string.
    log "FAIL $target: dump failed (exit $status, $(classify_dump_error "$work/$target.err"))"
    failed+=("$target")
    rm -f "$raw" "$raw.manifest.tsv"
    continue
  fi

  manifest_enc="$raw.manifest.tsv.age"
  if ! age --encrypt --recipient "$AGE_RECIPIENT" --output "$enc" "$raw" \
    || ! age --encrypt --recipient "$AGE_RECIPIENT" --output "$manifest_enc" "$raw.manifest.tsv"; then
    log "FAIL $target: encryption failed"
    failed+=("$target")
    rm -f "$raw" "$raw.manifest.tsv" "$enc" "$manifest_enc"
    continue
  fi
  tables="$(wc -l <"$raw.manifest.tsv")"
  rm -f "$raw" "$raw.manifest.tsv"

  manifest_name="${name%.age}.manifest.tsv.age"
  # The manifest goes up first: a dump object without its manifest never exists.
  if ! rclone copyto --s3-no-check-bucket "$manifest_enc" "r2:$BACKUP_BUCKET/daily/$manifest_name" \
    || ! rclone copyto --s3-no-check-bucket "$enc" "r2:$BACKUP_BUCKET/daily/$name"; then
    log "FAIL $target: upload failed"
    failed+=("$target")
    rm -f "$enc" "$manifest_enc"
    continue
  fi
  # Weekly (Sunday) and monthly (1st) copies live under their own prefixes so R2 lifecycle
  # rules can expire each tier on its own schedule.
  copy_ok=1
  for tier in weekly monthly; do
    if { [ "$tier" = weekly ] && [ "$day_of_week" = "7" ]; } || { [ "$tier" = monthly ] && [ "$day_of_month" = "01" ]; }; then
      rclone copyto --s3-no-check-bucket "$manifest_enc" "r2:$BACKUP_BUCKET/$tier/$manifest_name" || copy_ok=0
      rclone copyto --s3-no-check-bucket "$enc" "r2:$BACKUP_BUCKET/$tier/$name" || copy_ok=0
    fi
  done
  if [ "$copy_ok" = 0 ]; then
    log "FAIL $target: weekly/monthly copy failed"
    failed+=("$target")
    rm -f "$enc" "$manifest_enc"
    continue
  fi

  bytes="$(stat -c %s "$enc")"
  total_bytes=$((total_bytes + bytes))
  succeeded=$((succeeded + 1))
  log "OK $target $bytes bytes, $tables tables -> daily/$name"
  rm -f "$enc" "$manifest_enc"
done

ok=true
[ "${#failed[@]}" -gt 0 ] && ok=false
log "DONE ok=$ok succeeded=$succeeded failed=${#failed[@]} bytes=$total_bytes"

if [ -n "${HEARTBEAT_URL:-}" ]; then
  failed_json="$(printf '%s\n' "${failed[@]+"${failed[@]}"}" | jq -R . | jq -sc 'map(select(length > 0))')"
  body="$(jq -nc --argjson ok "$ok" --argjson succeeded "$succeeded" --argjson failed "$failed_json" \
    --argjson bytes "$total_bytes" --arg stamp "$stamp" \
    '{job: "db-backup", ok: $ok, succeeded: $succeeded, failed: $failed, bytes: $bytes, stamp: $stamp}')"
  if ! curl --silent --show-error --fail --max-time 20 --retry 3 \
    -H "Authorization: Bearer ${HEARTBEAT_TOKEN:-}" -H 'Content-Type: application/json' \
    --data "$body" "$HEARTBEAT_URL" >/dev/null; then
    log "WARN heartbeat failed; the monitor will alert on the missing heartbeat"
  fi
fi

[ "$ok" = true ]
