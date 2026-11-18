# Runbook: database backups

## Alerts and what to do

| Telegram alert | Meaning | First steps |
|---|---|---|
| `🔴 db-backup… run failed: a, b` | The nightly run finished, but the listed targets failed | Open the Railway service logs for that night. Each `FAIL <target>` line has a category (`permission denied`, `authentication failed`, `connection failed`, …). Fix it, then trigger a run (see below) |
| `⏰ db-backup… has not reported for over 26h` | No run reported: the cron did not fire, the container crashed before reporting, or the heartbeat call failed | Check the Railway service's deployments and logs. If the run itself succeeded, check that `HEARTBEAT_URL` / `HEARTBEAT_TOKEN` match the monitor |

## Trigger a run now

Railway cron services have no "run now" button. Set the cron schedule to a minute a few
minutes ahead, redeploy, wait for the run, then set it back to `0 19 * * *` and redeploy.

## Restore drill (monthly; the monitor's `restore-drill` heartbeat alerts after 35 days)

`scripts/restore-drill.sh` does the whole drill: for each target it takes the newest daily backup
that has a manifest, restores it into a uniquely named scratch database, recounts every table,
compares with the manifest (written from the same snapshot as the dump) and drops the scratch
database. Missing roles named by row-level security policies are created as NOLOGIN first.

1. In Railway project `ops-backups`, create three services:
   - `drill-postgres`: image `postgres:18.0`, variables `POSTGRES_USER=drill`, a random
     alphanumeric `POSTGRES_PASSWORD`, `POSTGRES_DB=postgres`.
   - `drill-mysql`: image `mysql:9.4.0`, a random alphanumeric `MYSQL_ROOT_PASSWORD`.
   - `restore-drill`: source `bookchaowalit/platform-db-backup`, start command
     `/app/scripts/restore-drill.sh`, restart policy NEVER, cron a few minutes ahead. Variables:
     `DRILL_TARGETS` (e.g. `empire ev3 tma platform-security`; cover every engine, and always include
     `platform-security`: its audit log is append-only and cannot be recreated), `DRILL_PG_ADMIN_URL=postgresql://drill:${{drill-postgres.POSTGRES_PASSWORD}}@drill-postgres.railway.internal:5432/postgres`,
     `DRILL_MYSQL_ADMIN_URL=mysql://root:${{drill-mysql.MYSQL_ROOT_PASSWORD}}@drill-mysql.railway.internal:3306/mysql`,
     `AGE_IDENTITY` (from Infisical `/db-backup`), `BACKUP_BUCKET=db-backups`, the `RCLONE_CONFIG_R2_*`
     and `HEARTBEAT_TOKEN` as references to `db-backup`, and
     `HEARTBEAT_URL=https://monitor.bookchaowalit.com/heartbeat/restore-drill`.
2. Wait for the run. Each target logs `OK <target> <object>: <tables> tables, <rows> rows match
   the manifest (<seconds>s)`, and the heartbeat records the result.
3. **Delete all three services right away.** `restore-drill` holds the decryption key.
4. Record the result (date, targets, objects, tables, rows, durations) in the operations log.

Drill 2026-11-18 15:18 UTC, all 44 targets: 43 matched their manifests (largest: x-intel 18 tables /
25,670 rows, income-pipeline 27 / 24,543, knowledge 3 / 6,533; 1–5 s each). **empire failed**: the
Neon dump carries `ALTER COLUMN … SET (pg_attver=N)` (Neon-internal column option, from the
2026-11-13 tenancy tables) that vanilla PostgreSQL rejects, so empire could not be restored outside
Neon. Fixed by `strip_neon_column_options` (lib.sh, used by both restore paths); empire then
restored: 34 tables / 150,474 rows match. Rerun 15:35 UTC with the fix: **44/44 passed**; the drill
services were deleted at once.

One-schema targets (`BACKUP_SCHEMA_<NAME>`) now fail the nightly backup with the category
`cross-schema dependency` when anything in the schema depends on another schema — a foreign key,
a view or rule reading another schema, a column type from another schema, or a partition or
inheritance child across the boundary (such a dump cannot restore alone, or its manifest counts
rows the dump lacks);
x-intel restored cleanly in both drills and the check counts 0 for it (2026-11-18).

First drill, 2026-10-18 06:12 UTC: empire 32 tables / 71,613 rows (3 s), ev3 129 / 1,544 (4 s),
tma 74 / 1,438 (11 s). All matched the manifests. The previous run had found the missing
policy roles.

## Second copy (3-2-1, since 2026-11-18)

R2 `db-backups` is the first copy. The homelab file server host `beelink` (192.168.152.10, tailnet
`beelink`) keeps a second copy on its own disk, so losing the Cloudflare account or the bucket
does not lose the backups.

- `/usr/local/bin/db-backups-mirror.sh`, run by `db-backups-mirror.timer` daily at 20:30 UTC
  (03:30 Bangkok, after the 19:00 UTC backup). Copies into `/var/lib/db-backups-mirror` (0700).
- **Read-only** bucket-scoped R2 token (Cloudflare token `db-backups-mirror-readonly (beelink)`,
  Infisical `/db-backup` `MIRROR_R2_*`): the host can read, never write or delete, the bucket.
- **Copy, never sync, never overwrite**: objects removed from R2 (retention, or a wipe) stay in the
  mirror, and `--immutable` refuses to replace a mirrored object whose R2 copy changed (backup
  objects are never rewritten, so a change is damage or tampering): the run fails `copy` and the
  mirror keeps its copy. The script prunes only its own `*.age` files under `daily/`, `weekly/`, `monthly/` older
  than 400 days, and never after a failed copy.
- Objects stay **age-encrypted**. The host has no `AGE_IDENTITY`; the key never goes there.
- After the copy, `rclone check --one-way` confirms every bucket object is in the mirror with the
  same hash. Freshness is checked against a target list that does not come from the bucket alone:
  bucket `daily/` prefixes + every target the mirror has ever held + `/etc/db-backups-mirror/expected`,
  minus `/etc/db-backups-mirror/retired`. Each must have a manifest newer than 36 h **and** the dump
  with the same name stem beside it (the pair `restore-drill.sh` picks), so a prefix deleted from R2
  or a lost dump still shows up as `stale:<target>`. **Add a new backup target to `expected`;
  retire one by adding it to `retired`.**
- Heartbeat `db-backup-mirror` (26 h). `ok:false` names the failed step: `copy`, `check`, `list`
  or `stale:<targets>`. Logs: `journalctl -u db-backups-mirror.service`.
- Env file `/etc/db-backups-mirror/env` (0600) holds the token and `HEARTBEAT_TOKEN`; rebuild it
  from Infisical when either rotates. Run now: `systemctl start db-backups-mirror.service`.
- Source of truth for the script and units: `mirror/` in this repository (CI shellchecks it).
  Install: copy `mirror/db-backups-mirror.sh` to `/usr/local/bin/`, the two units to
  `/etc/systemd/system/`, write `/etc/db-backups-mirror/env` (0600) with
  `RCLONE_CONFIG_R2_TYPE=s3`, `RCLONE_CONFIG_R2_PROVIDER=Cloudflare`,
  `RCLONE_CONFIG_R2_ACCESS_KEY_ID` / `RCLONE_CONFIG_R2_SECRET_ACCESS_KEY` / `RCLONE_CONFIG_R2_ENDPOINT`
  (from Infisical `/db-backup` `MIRROR_R2_*`), `HEARTBEAT_TOKEN` (Infisical `/monitoring`) and
  `HEARTBEAT_URL=https://monitor.bookchaowalit.com/heartbeat/db-backup-mirror`, create
  `/etc/db-backups-mirror/expected` (one target per line) and `retired`, then
  `systemctl daemon-reload && systemctl enable --now db-backups-mirror.timer`.

### Restore from the mirror when R2 is unavailable

Both `restore.sh` and `restore-drill.sh` read through the rclone remote `r2:`. Point that remote
at a local copy of the mirror (rclone `alias`) and they run unchanged, without R2:

1. On a disposable machine or container that will hold the key (never the mirror host), copy the
   objects you need from `beelink:/var/lib/db-backups-mirror/` into `<dir>/db-backups/`, keeping
   the `daily/<target>/` layout. For a drill, copy the newest `*.manifest.tsv.age` of each target
   and the `.age` dump with the same name stem.
2. Set `RCLONE_CONFIG_R2_TYPE=alias`, `RCLONE_CONFIG_R2_REMOTE=<dir>`, `BACKUP_BUCKET=db-backups`
   (so `r2:db-backups/daily/...` resolves to `<dir>/db-backups/daily/...`), plus `AGE_IDENTITY`
   (drill) or `AGE_IDENTITY_FILE` (restore) from Infisical `/db-backup`.
3. Prove the copy first with `restore-drill.sh` into a scratch PostgreSQL, then run `restore.sh`.

Verified 2026-11-18 with the backup image in Docker and a scratch `postgres:18.0`: habits,
platform-security and empire restored from the mirror copy and matched their manifests.

First run 2026-11-18 15:07 UTC: 44 targets, 1,640 objects, 856 MB, check passed.

## Rotating credentials

- **R2 key:** create a new bucket-scoped token (Object Read & Write on `db-backups` only), update
  Infisical `/db-backup` and every `db-backup` service's `RCLONE_CONFIG_R2_*`, then revoke the old token.
- **age key pair:** generate a new pair, update `AGE_RECIPIENT` everywhere and store the new
  identity in Infisical. **Keep the old identity**: older backups can only be decrypted with it.
- **Neon `db_backup` role:** reset its password with the Neon API and update `BACKUP_URL_*`.
