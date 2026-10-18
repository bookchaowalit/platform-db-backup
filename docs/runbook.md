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
     `DRILL_TARGETS` (e.g. `empire ev3 tma`; cover every engine), `DRILL_PG_ADMIN_URL=postgresql://drill:${{drill-postgres.POSTGRES_PASSWORD}}@drill-postgres.railway.internal:5432/postgres`,
     `DRILL_MYSQL_ADMIN_URL=mysql://root:${{drill-mysql.MYSQL_ROOT_PASSWORD}}@drill-mysql.railway.internal:3306/mysql`,
     `AGE_IDENTITY` (from Infisical `/db-backup`), `BACKUP_BUCKET=db-backups`, the `RCLONE_CONFIG_R2_*`
     and `HEARTBEAT_TOKEN` as references to `db-backup`, and
     `HEARTBEAT_URL=https://solo-empire-monitor.bookchaowalit.workers.dev/heartbeat/restore-drill`.
2. Wait for the run. Each target logs `OK <target> <object>: <tables> tables, <rows> rows match
   the manifest (<seconds>s)`, and the heartbeat records the result.
3. **Delete all three services right away.** `restore-drill` holds the decryption key.
4. Record the result (date, targets, objects, tables, rows, durations) in the operations log.

First drill, 2026-10-18 06:12 UTC: empire 32 tables / 71,613 rows (3 s), ev3 129 / 1,544 (4 s),
tma 74 / 1,438 (11 s). All matched the manifests. The previous run had found the missing
policy roles.

## Rotating credentials

- **R2 key:** create a new bucket-scoped token (Object Read & Write on `db-backups` only), update
  Infisical `/db-backup` and every `db-backup` service's `RCLONE_CONFIG_R2_*`, then revoke the old token.
- **age key pair:** generate a new pair, update `AGE_RECIPIENT` everywhere and store the new
  identity in Infisical. **Keep the old identity**: older backups can only be decrypted with it.
- **Neon `db_backup` role:** reset its password with the Neon API and update `BACKUP_URL_*`.
