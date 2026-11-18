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
set -a
# shellcheck source=/dev/null
. "${MIRROR_ENV_FILE:-/etc/db-backups-mirror/env}"
set +a
DEST="${DEST:-/var/lib/db-backups-mirror}"
KEEP_DAYS="${KEEP_DAYS:-400}"
FRESH_HOURS="${FRESH_HOURS:-36}"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
problems=()
mkdir -p "$DEST" && chmod 700 "$DEST"

# --immutable: backup objects are never rewritten (each run writes new names), so a changed
# source object is damage or tampering. rclone keeps the mirror copy and fails the copy instead.
if ! rclone copy r2:db-backups "$DEST" --immutable --s3-no-check-bucket --transfers 4 --log-level NOTICE; then
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
# The newest manifest must be fresh AND have its dump (same name stem) beside it: that pair is
# exactly what restore-drill.sh picks.
for t in $targets; do
  newest=$(find "$DEST/daily/$t" -name '*.manifest.tsv.age' -mmin -$((FRESH_HOURS * 60)) 2>/dev/null | sort | tail -n 1)
  if [ -z "$newest" ] || [ ! -s "${newest%.manifest.tsv.age}.age" ]; then
    stale+=("$t")
  fi
done
for t in "${stale[@]+"${stale[@]}"}"; do problems+=("stale:$t"); done

# Prune only what this job writes (*.age under daily/weekly/monthly), and never after a failed
# copy: a broken run must not shrink the mirror.
if [[ " ${problems[*]+"${problems[*]}"} " != *" copy "* ]]; then
  for tier in daily weekly monthly; do
    [ -d "$DEST/$tier" ] && find "$DEST/$tier" -type f -name '*.age' -mtime +"$KEEP_DAYS" -delete
  done
fi
files=$(find "$DEST" -type f | wc -l)
size=$(du -sm "$DEST" | cut -f1)
ntargets=$(printf '%s\n' $targets | grep -c . || true)

# The monitor names and de-duplicates failures by the `failed` array (same contract as backup.sh):
# a different list alerts again. Entries are step names and target names, [a-z0-9:-] only.
failed_json=""
for p in "${problems[@]+"${problems[@]}"}"; do failed_json="$failed_json${failed_json:+,}\"${p//[^a-z0-9:-]/}\""; done
if [ "${#problems[@]}" -eq 0 ]; then ok=true; else ok=false; fi
log "ok=$ok targets=$ntargets files=$files size_mb=$size failed=[${problems[*]+"${problems[*]}"}]"
curl -fsS --max-time 20 -X POST -H "Authorization: Bearer $HEARTBEAT_TOKEN" -H 'Content-Type: application/json' \
  --data "{\"ok\":$ok,\"failed\":[$failed_json],\"targets\":$ntargets,\"files\":$files,\"size_mb\":$size}" \
  "$HEARTBEAT_URL" >/dev/null || log "heartbeat failed"
[ "$ok" = true ]
