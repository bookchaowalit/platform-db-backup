# Runbook: database backups

## Alerts and what to do

| Telegram alert | Meaning | First steps |
|---|---|---|
| `🔴 db-backup… run failed: a, b` | The nightly run finished, but the listed targets failed | Open the Railway service logs for that night. Each `FAIL <target>` line has a category (`permission denied`, `authentication failed`, `connection failed`, …). Fix it, then trigger a run (see below) |
| `⏰ db-backup… has not reported for over 26h` | No run reported: the cron did not fire, the container crashed before reporting, or the heartbeat call failed | Check the Railway service's deployments and logs. If the run itself succeeded, check that `HEARTBEAT_URL` / `HEARTBEAT_TOKEN` match the monitor |

## Trigger a run now

Railway cron services have no "run now" button. Set the cron schedule to a minute a few
minutes ahead, redeploy, wait for the run, then set it back to `0 19 * * *` and redeploy.

## Restore drill (do this monthly and after any change to the job)

1. Create a scratch target: a Neon branch of the source project, or a temporary Railway Postgres.
2. Write `AGE_IDENTITY` from Infisical `/db-backup` to a temp file with mode 0600.
3. Run `scripts/restore.sh daily/<target>/<stamp>.dump.age "$SCRATCH_URL"` from a container built
   from this repo (the local machine has no PostgreSQL client tools).
4. Compare row counts of the main tables against production, and record the result (date,
   target, object, counts, duration) in the operations log.
5. Delete the scratch target and the temp key file.

## Rotating credentials

- **R2 key:** create a new bucket-scoped token (Object Read & Write on `db-backups` only), update
  Infisical `/db-backup` and every `db-backup` service's `RCLONE_CONFIG_R2_*`, then revoke the old token.
- **age key pair:** generate a new pair, update `AGE_RECIPIENT` everywhere and store the new
  identity in Infisical. **Keep the old identity**: older backups can only be decrypted with it.
- **Neon `db_backup` role:** reset its password with the Neon API and update `BACKUP_URL_*`.
