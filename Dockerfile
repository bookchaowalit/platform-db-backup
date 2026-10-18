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
      unzip \
 && rm -rf /var/lib/apt/lists/*

# Debian's rclone (1.60) fails its first R2 upload attempt with NotImplemented; use a pinned,
# checksum-verified upstream release instead.
ARG RCLONE_VERSION=1.71.1
ARG RCLONE_SHA256=417e3da236f3a12d292da4e7287d67b1df558b8c2b280d092e563958ed724be7
RUN curl -fsSL -o /tmp/rclone.zip "https://downloads.rclone.org/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-amd64.zip" \
 && echo "${RCLONE_SHA256}  /tmp/rclone.zip" | sha256sum -c - \
 && unzip -q -j /tmp/rclone.zip "rclone-v${RCLONE_VERSION}-linux-amd64/rclone" -d /usr/local/bin \
 && chmod 0755 /usr/local/bin/rclone \
 && rm /tmp/rclone.zip

RUN useradd --create-home --uid 10001 dbbackup
WORKDIR /app
COPY scripts/ /app/scripts/
RUN chmod 0755 /app/scripts/*.sh

USER dbbackup
# CMD, not ENTRYPOINT, so a Railway start command can run restore-drill.sh with the same image.
CMD ["/app/scripts/backup.sh"]
