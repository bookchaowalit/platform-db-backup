# Nightly logical backups of every production database, run as a Railway cron service.
# pg_dump 18 can dump any older PostgreSQL server (Neon 16/17, Railway 16-18).
FROM postgres:18-bookworm

# apt-get upgrade takes Debian security fixes newer than the base tag. gosu is only used by
# docker-entrypoint.sh to start a postgres server, which this image never does (CMD runs the
# scripts as the dbbackup user), and its Go runtime is what the Trivy image scan flags.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      age \
      ca-certificates \
      curl \
      default-mysql-client \
      jq \
      unzip \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /usr/local/bin/gosu

# Debian's rclone (1.60) fails its first R2 upload attempt with NotImplemented; use a pinned,
# checksum-verified upstream release instead.
ARG RCLONE_VERSION=1.76.0
ARG RCLONE_SHA256=b00f00b3266c3764413afe599d3ec316f6f43b3e0ea8a0bc1d186d2133e46df7
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
