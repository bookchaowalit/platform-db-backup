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

## Deployments

| Railway service | Databases | Connection | Heartbeat job |
|---|---|---|---|
| `ops-backups/db-backup` | the 30 Neon databases of own services | dedicated `db_backup` role per Neon project (Neon roles inherit `pg_read_all_data` via `neon_superuser`) | `db-backup` |
| `db-backup` inside each Railway project with a database (ev3, a2n, tma, scannpop, teeparinwat, enchanting-dream) | that project's Postgres / PostGIS / MySQL | reference variable such as `${{Postgres.DATABASE_URL}}` over the private network, so no database is exposed publicly | `db-backup-<project>` |

When a Neon `db_backup` password is reset, update the matching `BACKUP_URL_*` in `ops-backups`.
The next run fails loudly until you do. Railway references follow rotations automatically.

Secrets live in Infisical: `/db-backup` (R2 key scoped to this bucket only, `AGE_RECIPIENT`,
and `AGE_IDENTITY`, the decryption key) and `/monitoring` (`HEARTBEAT_TOKEN`).

## What a run checks

- `pg_dump --format=custom`, then `pg_restore --file=/dev/null`, which reads every data block, so
  a truncated or corrupt archive fails the target before it is encrypted.
- MySQL: `mysqldump --single-transaction`, then `gzip -t`.
- One failed target never stops the others. The job exits non-zero and the heartbeat lists the
  failed targets. An empty `BACKUP_TARGETS` is a configuration error, not a successful run.
- Logs never contain raw client errors (libpq and mysql can echo parts of a connection string);
  a failure is reported as a short category such as `permission denied` or `connection failed`.

## Restore

```bash
# AGE_IDENTITY from Infisical /db-backup, written to a 0600 temp file
AGE_IDENTITY_FILE=/tmp/age-key.txt BACKUP_BUCKET=db-backups \
  scripts/restore.sh daily/habits/2026-10-18T0200.dump.age "$SCRATCH_DATABASE_URL"
```

`restore.sh` renders the archive to SQL first (a damaged file fails before the target changes),
then applies it in one transaction that stops on the first error. It works against PostgreSQL 16
and newer.

Always restore into a scratch database (for example a Neon branch) first and check it. Restoring
over production needs a written restore decision. See `docs/runbook.md`.
