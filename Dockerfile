# Nightly logical backups of every production database, run as a Railway cron service.
# pg_dump 18 can dump any older PostgreSQL server (Neon 16/17, Railway 16-18).
FROM postgres:18.0-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      age \
      ca-certificates \
      curl \
      default-mysql-client \
      jq \
      rclone \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 10001 dbbackup
WORKDIR /app
COPY scripts/ /app/scripts/
RUN chmod 0755 /app/scripts/*.sh

USER dbbackup
ENTRYPOINT ["/app/scripts/backup.sh"]
