# platform-db-backup

Nightly, encrypted, off-site logical backups of every production database (Neon PostgreSQL,
Railway PostgreSQL/PostGIS and Railway MySQL). It runs as a **Railway cron service**, dumps every
target, encrypts each dump with [age](https://age-encryption.org), uploads it to **Cloudflare R2**
and reports to the uptime monitor (`platform-uptime-worker`). The monitor sends a Telegram alert
when a run fails, or when no run has reported in 26 hours.

Neon's built-in point-in-time restore still applies. These dumps are the independent copy that
survives losing the Neon or Railway account, a deleted project, or a mistake that outlives the
provider's restore window.

## Schedule and retention

| Tier | Written | Kept (R2 lifecycle rule) | Prefix |
|---|---|---|---|
| Daily | every night, 02:00 Asia/Bangkok (cron `0 19 * * *` UTC) | 14 days | `daily/` |
| Weekly | Sunday's dump | 56 days (8 weeks) | `weekly/` |
| Monthly | the dump of the 1st | 365 days (12 months) | `monthly/` |

Object names: `<tier>/<target>/<YYYY-MM-DDTHHMM>.<dump|sql.gz>.age`.

## Configuration (Railway service variables)

| Variable | Meaning |
|---|---|
| `BACKUP_TARGETS` | Space-separated target names, e.g. `habits tax ev3 tma` |
| `BACKUP_URL_<NAME>` | Connection URL for each target (`postgres://…` or `mysql://…`). `NAME` is the target upper-cased, with `-` replaced by `_` |
| `AGE_RECIPIENT` | age **public** key. The private key is kept offline by the owner and never stored on Railway |
| `BACKUP_BUCKET` | R2 bucket (`db-backups`) |
| `RCLONE_CONFIG_R2_TYPE` | `s3` |
| `RCLONE_CONFIG_R2_PROVIDER` | `Cloudflare` |
| `RCLONE_CONFIG_R2_ACCESS_KEY_ID` / `RCLONE_CONFIG_R2_SECRET_ACCESS_KEY` | R2 API token scoped to this bucket only (Object Read & Write) |
| `RCLONE_CONFIG_R2_ENDPOINT` | `https://<account-id>.r2.cloudflarestorage.com` |
| `HEARTBEAT_URL` / `HEARTBEAT_TOKEN` | Monitor endpoint `…/heartbeat/db-backup` and its bearer token |
| `BACKUP_TZ` | Optional, defaults to `Asia/Bangkok` |

Railway databases in other projects are reached through their public TCP proxy URL
(`DATABASE_PUBLIC_URL`), because reference variables don't cross projects. When a database
password is rotated, update the matching `BACKUP_URL_*` here too. The next run fails loudly
until you do.

## What a run checks

- `pg_dump --format=custom`, then `pg_restore --list` on the file, so a truncated or corrupt
  archive fails the target before it is encrypted.
- MySQL: `mysqldump --single-transaction`, then `gzip -t`.
- One failed target never stops the others. The job exits non-zero and the heartbeat lists the
  failed targets.

## Restore

```bash
AGE_IDENTITY_FILE=~/path/to/db-backup-age-key.txt BACKUP_BUCKET=db-backups \
  scripts/restore.sh daily/habits/2026-10-18T0200.dump.age "$SCRATCH_DATABASE_URL"
```

Always restore into a scratch database (for example a Neon branch) first and check it. Restoring
over production needs a written restore decision. See `docs/runbook.md`.
