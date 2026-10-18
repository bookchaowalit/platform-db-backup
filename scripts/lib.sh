#!/usr/bin/env bash
# Shared helpers for backup.sh, restore.sh and restore-drill.sh.

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

# Point a postgres:// URL at another database: replace the path and drop any dbname= query
# parameter, which libpq would otherwise let override the path.
pg_url_with_database() {
  local url="$1" db="$2" base query="" param
  local -a params=() kept=()
  base="${url%%\?*}"
  if [ "$base" != "$url" ]; then
    IFS='&' read -r -a params <<<"${url#*\?}"
    for param in "${params[@]}"; do
      [[ "$param" == dbname=* ]] || kept+=("$param")
    done
    [ "${#kept[@]}" -gt 0 ] && query="?$(IFS='&'; printf '%s' "${kept[*]}")"
  fi
  printf '%s/%s%s' "${base%/*}" "$db" "$query"
}

# Map a client error file to a short, secret-free category for the logs.
classify_dump_error() {
  local file="$1"
  if [ ! -s "$file" ]; then echo "no error output"
  elif grep -qi 'permission denied' "$file"; then echo "permission denied"
  elif grep -qiE 'password authentication failed|access denied' "$file"; then echo "authentication failed"
  elif grep -qiE 'could not connect|connection refused|timeout|could not translate host|unknown mysql server host' "$file"; then echo "connection failed"
  elif grep -qiE 'server version|version mismatch' "$file"; then echo "client/server version mismatch"
  elif grep -qiE 'already exists|does not exist' "$file"; then echo "object exists / missing"
  elif grep -qiE 'invalid|unrecognized|syntax' "$file"; then echo "invalid connection URL, option or SQL"
  else echo "see a manual run for details"
  fi
}

# A manifest is "name<TAB>count" lines with integer counts; anything else means a failed count.
valid_manifest() {
  [ -f "$1" ] && ! grep -qvE $'^[^\t]+\t[0-9]+$' "$1"
}

# pg_restore emits `SET transaction_timeout = 0;` in the script preamble; servers before 17
# reject it. Remove it only from the preamble (before the first CREATE/ALTER/COPY/SELECT), so a
# data row that happens to start with the same text is never touched.
strip_pg_preamble_setting() {
  awk '!body && /^SET transaction_timeout = / {next}
       /^(CREATE|ALTER|COPY|SELECT|COMMENT) / {body = 1}
       {print}' "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}

PG_COUNT_SQL="SELECT table_schema || '.' || table_name,
       (xpath('/row/c/text()', query_to_xml(
          format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text
FROM information_schema.tables
WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY 1"

# Exact row count per base table of a live database, as "schema.table<TAB>count" lines.
pg_table_counts() {
  psql --dbname="$1" --no-psqlrc --quiet --no-align --tuples-only --field-separator=$'\t' \
    --set ON_ERROR_STOP=1 --command="$PG_COUNT_SQL"
}

# pg_dump plus a row-count manifest taken from the very same snapshot: one REPEATABLE READ
# transaction stays open, exports its snapshot to pg_dump and then counts every table, so rows
# written meanwhile can never make the manifest disagree with the dump.
#   pg_dump_with_manifest <url> <dump-file> <manifest-file> <stderr-file>
pg_dump_with_manifest() {
  local url="$1" out="$2" manifest="$3" err="$4" snapshot="" line="" status=0
  coproc SNAP {
    psql --dbname="$url" --no-psqlrc --quiet --no-align --tuples-only --field-separator=$'\t' \
      --set ON_ERROR_STOP=1 2>>"$err"
  }
  local to_psql="${SNAP[1]}" from_psql="${SNAP[0]}" psql_pid="$SNAP_PID"
  printf '%s\n' "BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY;" "SELECT pg_export_snapshot();" 1>&"$to_psql"
  if ! IFS= read -r -t 120 snapshot <&"$from_psql" || [[ ! "$snapshot" =~ ^[0-9A-Fa-f-]+$ ]]; then
    kill "$psql_pid" 2>/dev/null
    wait "$psql_pid" 2>/dev/null
    return 1
  fi
  pg_dump --snapshot="$snapshot" --format=custom --compress=6 --no-owner --no-privileges \
    --dbname="$url" --file="$out" 2>>"$err" || status=1
  if [ "$status" = 0 ]; then
    printf '%s;\n' "$PG_COUNT_SQL" "SELECT '__END__'" 1>&"$to_psql"
    : >"$manifest"
    while IFS= read -r -t 600 line <&"$from_psql"; do
      [ "$line" = "__END__" ] && break
      printf '%s\n' "$line" >>"$manifest"
    done
    [ "$line" = "__END__" ] || status=1
  fi
  printf '%s\n' "COMMIT;" '\q' 1>&"$to_psql" 2>/dev/null
  wait "$psql_pid" 2>/dev/null
  [ "$status" = 0 ] \
    && pg_restore --file=/dev/null "$out" 2>>"$err" \
    && valid_manifest "$manifest"
}

# Row counts taken from a mysqldump file written with --skip-extended-insert (one INSERT per
# row), so they describe exactly what the dump contains. Tables without rows count as 0.
mysql_manifest_from_dump() {
  gunzip -c "$1" | awk '
    /^CREATE TABLE `/ { split($0, p, "`"); if (!(p[2] in n)) n[p[2]] = 0 }
    /^INSERT INTO `/  { split($0, p, "`"); n[p[2]]++ }
    END { for (t in n) printf "%s\t%d\n", t, n[t] }' | LC_ALL=C sort
}

# Exact row count per base table of a live MySQL database; parse_mysql_url must have run first.
# Fails if any count fails, instead of emitting an empty count.
mysql_table_counts() {
  local tables table count
  tables="$(MYSQL_PWD="$MYSQL_URL_PASSWORD" mysql --host="$MYSQL_URL_HOST" --port="$MYSQL_URL_PORT" \
    --user="$MYSQL_URL_USER" --batch --skip-column-names "$MYSQL_URL_DATABASE" \
    --execute="SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'")" || return 1
  {
    while IFS= read -r table; do
      [ -n "$table" ] || continue
      count="$(MYSQL_PWD="$MYSQL_URL_PASSWORD" mysql --host="$MYSQL_URL_HOST" --port="$MYSQL_URL_PORT" \
        --user="$MYSQL_URL_USER" --batch --skip-column-names "$MYSQL_URL_DATABASE" \
        --execute="SELECT COUNT(*) FROM \`${table//\`/\`\`}\`")" || return 1
      [[ "$count" =~ ^[0-9]+$ ]] || return 1
      printf '%s\t%s\n' "$table" "$count"
    done <<<"$tables"
  } >"${MYSQL_COUNTS_OUT:?set MYSQL_COUNTS_OUT}.unsorted" || return 1
  LC_ALL=C sort "$MYSQL_COUNTS_OUT.unsorted" >"$MYSQL_COUNTS_OUT" && rm -f "$MYSQL_COUNTS_OUT.unsorted"
}
