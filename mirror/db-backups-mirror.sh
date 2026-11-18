#!/usr/bin/env bash
# Second copy of the database backups (3-2-1). Copies R2 bucket db-backups to this host with a
# READ-ONLY bucket-scoped token. Objects stay age-encrypted: this host never holds the decryption
# key. Copy-only (never sync): a wiped or corrupted bucket cannot empty the mirror; local files
# older than KEEP_DAYS are pruned here instead. Reports heartbeat db-backup-mirror.
# Source of truth: platform-db-backup mirror/ (install steps in docs/runbook.md "Second copy").
# Target lists are newline-separated names ([a-z0-9-]), split on purpose (SC2086); the env file
# exists only on the mirror host (SC1091).
# shellcheck disable=SC1091,SC2086
set -uo pipefail
set -a; . /etc/db-backups-mirror/env; set +a
DEST="${DEST:-/var/lib/db-backups-mirror}"
KEEP_DAYS="${KEEP_DAYS:-400}"
FRESH_HOURS="${FRESH_HOURS:-36}"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
problems=()
mkdir -p "$DEST" && chmod 700 "$DEST"

if ! rclone copy r2:db-backups "$DEST" --s3-no-check-bucket --transfers 4 --log-level NOTICE; then
  problems+=("copy")
fi
if ! rclone check r2:db-backups "$DEST" --one-way --s3-no-check-bucket --log-level ERROR; then
  problems+=("check")
fi

# Expected targets do not come from the bucket alone, so a prefix deleted from R2 (or a target
# that stops being backed up) still shows up as stale: bucket daily/ dirs + every target this
# mirror has ever held + /etc/db-backups-mirror/expected, minus /etc/db-backups-mirror/retired.
stale=()
bucket=$(rclone lsf --dirs-only r2:db-backups/daily/ 2>/dev/null | tr -d '/')
[ -n "$bucket" ] || problems+=("list")
held=$(find "$DEST/daily" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)
expected=$(grep -v '^#' /etc/db-backups-mirror/expected 2>/dev/null)
retired=$(grep -v '^#' /etc/db-backups-mirror/retired 2>/dev/null)
targets=$(printf '%s\n' $bucket $held $expected | grep . | sort -u | grep -vxF -f <(printf '%s\n' $retired | grep . || echo '#none') || true)
for t in $targets; do
  if [ -z "$(find "$DEST/daily/$t" -name '*.manifest.tsv.age' -mmin -$((FRESH_HOURS * 60)) 2>/dev/null | head -n 1)" ]; then
    stale+=("$t")
  fi
done
[ "${#stale[@]}" -eq 0 ] || problems+=("stale:${stale[*]}")

find "$DEST" -type f -mtime +"$KEEP_DAYS" -delete
files=$(find "$DEST" -type f | wc -l)
size=$(du -sm "$DEST" | cut -f1)
ntargets=$(printf '%s\n' $targets | grep -c . || true)

if [ "${#problems[@]}" -eq 0 ]; then ok=true; detail="targets=$ntargets files=$files size_mb=$size"
else ok=false; detail="failed: ${problems[*]} (files=$files)"; fi
detail="${detail:0:300}"
log "ok=$ok $detail"
curl -fsS --max-time 20 -X POST -H "Authorization: Bearer $HEARTBEAT_TOKEN" -H 'Content-Type: application/json' \
  --data "{\"ok\":$ok,\"detail\":\"${detail//\"/}\"}" "$HEARTBEAT_URL" >/dev/null || log "heartbeat failed"
[ "$ok" = true ]
