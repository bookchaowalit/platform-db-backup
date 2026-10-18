#!/usr/bin/env bash
# Shared helpers for backup.sh and restore.sh.

# Decode %XX escapes exactly once. "+" stays literal (URI userinfo is not form encoding) and
# existing backslashes are protected from printf's escape handling.
urldecode() {
  local value="${1//\\/\\\\}"
  printf '%b' "${value//%/\\x}"
}

# Parse mysql://user[:password]@host[:port]/database[?params] into MYSQL_URL_* variables.
# Handles percent-encoded components, a missing password and bracketed IPv6 hosts.
parse_mysql_url() {
  local url="$1"
  local re='^mysql://([^:@/]+)(:([^@]*))?@(\[[0-9A-Fa-f:.]+\]|[^:/?]+)(:([0-9]+))?/([^?]+)'
  if [[ ! "$url" =~ $re ]]; then
    return 1
  fi
  MYSQL_URL_USER="$(urldecode "${BASH_REMATCH[1]}")"
  MYSQL_URL_PASSWORD="$(urldecode "${BASH_REMATCH[3]}")"
  MYSQL_URL_HOST="${BASH_REMATCH[4]#[}"
  MYSQL_URL_HOST="${MYSQL_URL_HOST%]}"
  MYSQL_URL_PORT="${BASH_REMATCH[6]:-3306}"
  MYSQL_URL_DATABASE="$(urldecode "${BASH_REMATCH[7]}")"
  export MYSQL_URL_USER MYSQL_URL_PASSWORD MYSQL_URL_HOST MYSQL_URL_PORT MYSQL_URL_DATABASE
}

# Map a client error file to a short, secret-free category for the logs.
classify_dump_error() {
  local file="$1"
  if grep -qi 'permission denied' "$file"; then echo "permission denied"
  elif grep -qiE 'password authentication failed|access denied' "$file"; then echo "authentication failed"
  elif grep -qiE 'could not connect|connection refused|timeout|could not translate host|unknown mysql server host' "$file"; then echo "connection failed"
  elif grep -qiE 'server version|version mismatch' "$file"; then echo "client/server version mismatch"
  elif grep -qiE 'invalid|unrecognized|syntax' "$file"; then echo "invalid connection URL or option"
  else echo "see a manual run for details"
  fi
}

# Exact row count per base table, as "schema.table<TAB>count" lines sorted by name.
pg_table_counts() {
  psql --dbname="$1" --no-psqlrc --quiet --no-align --tuples-only --field-separator=$'\t' --command="
    SELECT table_schema || '.' || table_name,
           (xpath('/row/c/text()', query_to_xml(
              format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text
    FROM information_schema.tables
    WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema')
    ORDER BY 1"
}

# Same for MySQL; parse_mysql_url must have run for the database first.
mysql_table_counts() {
  local table
  MYSQL_PWD="$MYSQL_URL_PASSWORD" mysql --host="$MYSQL_URL_HOST" --port="$MYSQL_URL_PORT" \
    --user="$MYSQL_URL_USER" --batch --skip-column-names "$MYSQL_URL_DATABASE" \
    --execute="SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE' ORDER BY table_name" \
    | while IFS= read -r table; do
        printf '%s\t%s\n' "$table" "$(MYSQL_PWD="$MYSQL_URL_PASSWORD" mysql --host="$MYSQL_URL_HOST" \
          --port="$MYSQL_URL_PORT" --user="$MYSQL_URL_USER" --batch --skip-column-names \
          "$MYSQL_URL_DATABASE" --execute="SELECT COUNT(*) FROM \`${table//\`/\`\`}\`")"
      done
}
