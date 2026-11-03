# Product

<!-- impeccable:product-schema 1 -->

## Platform

scheduled job (Railway cron services running shell scripts in one Docker image)

## Users

- The owner, who needs an independent copy of every production database to restore from, and a
  Telegram alert when a nightly backup fails or does not run.

## Product Purpose

Nightly, encrypted, off-site logical backups of every production database (Neon PostgreSQL,
Railway PostgreSQL/PostGIS and Railway MySQL): dump each target, encrypt it with age to the
owner's public key, upload it to Cloudflare R2 with daily, weekly and monthly retention, and
report each run to the uptime monitor.

Success: every target has a fresh dump each night, the monitor alerts on a failed run or no run
within 26 hours, and a scheduled restore drill proves the dumps restore.

## Positioning

The independent copy that survives losing the Neon or Railway account, a deleted project, or a
mistake that outlives the provider's own restore window. Neon point-in-time restore still applies.

## Operating Context

- Railway cron (`0 19 * * *` UTC, 02:00 Asia/Bangkok): `ops-backups/db-backup` for the Neon
  databases, plus one `db-backup` service inside each Railway project with a database (README
  "Deployments"). Each reports to its own heartbeat job.
- Dumps are encrypted with age before upload; the private key is kept offline by the owner and
  in Infisical `/db-backup`, never on Railway. The R2 token is scoped to the backup bucket.
- Restores and the restore drill are in `docs/runbook.md`.
- CI: ShellCheck, the unit tests of `scripts/lib.sh` (`tests/`), an image build with a smoke
  test, and the shared security workflow, on GitHub-hosted runners (public repository).

Sentry waiver: there is no long-running process; each cron run reports success or a fixed failure category to its uptime-monitor heartbeat, which alerts on a failed run at once and on a missing run after 26 hours.

## Capabilities and Constraints

- Logs carry short, secret-free failure categories (`classify_dump_error`), never connection
  URLs or client error text.
- Retention is enforced by R2 lifecycle rules: daily 14 days, weekly 56 days, monthly 365 days.

## Measures

- Nightly runs reported `ok` per heartbeat job (target: every night).
- Restore drill results (target: every drill passes).
