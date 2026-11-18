#!/usr/bin/env bash
# Monthly automated restore drill (Railway cron service `restore-drill` in ops-backups, 1st of the
# month 03:00 UTC). Starts a throwaway PostgreSQL inside this container (the image is
# postgres:18-bookworm, run as a non-root user), points restore-drill.sh at it and drills every
# target that has daily backups in the bucket, so a new database is covered without editing
# anything. The server and its data live in a temp dir that is removed on exit. DRILL_TARGETS, when set, limits the run to those targets.
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

: "${BACKUP_BUCKET:?BACKUP_BUCKET is required}"
pgbin="$(find /usr/lib/postgresql -maxdepth 2 -type d -name bin | sort -V | tail -n 1)"
[ -x "$pgbin/initdb" ] || { echo "FATAL no PostgreSQL server binaries in this image" >&2; exit 2; }

# Hardening (a dump is untrusted input: anyone who could write the bucket could plant SQL):
# - the server starts with an EMPTY environment, so it never holds AGE_IDENTITY, R2 or heartbeat
#   credentials even if SQL reaches it;
# - no TCP: only a unix socket inside the 0700 temp dir;
# - restores run as `drill`, a NON-superuser (CREATEDB, CREATEROLE for the RLS policy roles), so
#   COPY ... TO PROGRAM, untrusted languages and file access are refused. BYPASSRLS only lets the
#   row counts see rows behind FORCE ROW LEVEL SECURITY, as the manifest (taken as owner) does.
scratch="$(mktemp -d)"   # mode 0700
stop_server() {
  env -i PATH="$PATH" "$pgbin/pg_ctl" -D "$scratch/db" -m fast -w stop >/dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap stop_server EXIT
env -i PATH="$PATH" "$pgbin/initdb" -D "$scratch/db" -U bootstrap --auth=trust -E UTF8 --no-instructions >/dev/null
env -i PATH="$PATH" "$pgbin/pg_ctl" -D "$scratch/db" -w -l "$scratch/server.log" \
  -o "-c listen_addresses='' -c unix_socket_directories=$scratch -c fsync=off" start >/dev/null
env -i PATH="$PATH" psql --host="$scratch" --username=bootstrap --dbname=postgres --no-psqlrc --quiet \
  --set ON_ERROR_STOP=1 --command="CREATE ROLE drill LOGIN CREATEDB CREATEROLE BYPASSRLS NOSUPERUSER" >/dev/null
export DRILL_PG_ADMIN_URL="postgresql://drill@/postgres?host=$scratch"

if [ -z "${DRILL_TARGETS:-}" ]; then
  if ! listing="$(rclone lsf --dirs-only "r2:$BACKUP_BUCKET/daily/" 2>/dev/null)" || [ -z "$listing" ]; then
    # Report it now instead of waiting for the 35-day staleness alert.
    echo "FAIL target discovery: could not list r2:$BACKUP_BUCKET/daily/" >&2
    if [ -n "${HEARTBEAT_URL:-}" ]; then
      curl --silent --fail --max-time 20 --retry 3 -H "Authorization: Bearer ${HEARTBEAT_TOKEN:-}" \
        -H 'Content-Type: application/json' --data '{"job":"restore-drill","ok":false,"failed":["target-discovery"]}' \
        "$HEARTBEAT_URL" >/dev/null 2>&1 || true
    fi
    exit 1
  fi
  DRILL_TARGETS="$(printf '%s' "$listing" | tr -d '/' | tr '\n' ' ')"
  export DRILL_TARGETS
fi
# Not exec: the trap must stop the scratch server after the drill reports its heartbeat.
"$(dirname "$0")/restore-drill.sh"
