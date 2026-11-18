#!/usr/bin/env bash
# Monthly automated restore drill (Railway cron service `restore-drill` in ops-backups, 1st of the
# month 03:00 UTC). Starts a throwaway PostgreSQL inside this container (the image is
# postgres:18-bookworm, run as a non-root user), points restore-drill.sh at it and drills every
# target that has daily backups in the bucket, so a new database is covered without editing
# anything. The server and its data live in a temp dir that is removed on exit; nothing is
# exposed outside the container. DRILL_TARGETS, when set, limits the run to those targets.
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

: "${BACKUP_BUCKET:?BACKUP_BUCKET is required}"
pgbin="$(find /usr/lib/postgresql -maxdepth 2 -type d -name bin | sort -V | tail -n 1)"
[ -x "$pgbin/initdb" ] || { echo "FATAL no PostgreSQL server binaries in this image" >&2; exit 2; }

scratch="$(mktemp -d)"
port=54329
stop_server() {
  "$pgbin/pg_ctl" -D "$scratch/db" -m fast -w stop >/dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap stop_server EXIT
"$pgbin/initdb" -D "$scratch/db" -U drill --auth=trust -E UTF8 --no-instructions >/dev/null
"$pgbin/pg_ctl" -D "$scratch/db" -w -l "$scratch/server.log" \
  -o "-c listen_addresses=127.0.0.1 -c port=$port -c unix_socket_directories=$scratch -c fsync=off" start >/dev/null
export DRILL_PG_ADMIN_URL="postgresql://drill@127.0.0.1:$port/postgres"

if [ -z "${DRILL_TARGETS:-}" ]; then
  DRILL_TARGETS="$(rclone lsf --dirs-only "r2:$BACKUP_BUCKET/daily/" 2>/dev/null | tr -d '/' | tr '\n' ' ')"
  export DRILL_TARGETS
fi
# Not exec: the trap must stop the scratch server after the drill reports its heartbeat.
"$(dirname "$0")/restore-drill.sh"
