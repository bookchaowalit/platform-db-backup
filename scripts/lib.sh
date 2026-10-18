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
      # libpq decodes keys before use, so %64bname is dbname too.
      [[ "$(urldecode "${param%%=*}")" == dbname ]] || kept+=("$param")
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

# Stop a coprocess: ask it to finish, then kill it if it is still running after 10 s.
stop_coproc() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  for _ in $(seq 1 10); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 0
}

# pg_dump plus a row-count manifest taken from the very same snapshot: one REPEATABLE READ
# transaction stays open, exports its snapshot to pg_dump and then counts every table, so rows
# written meanwhile can never make the manifest disagree with the dump. Every coprocess write
# and read is guarded (the callers ignore SIGPIPE), and the coprocess is always stopped.
#   pg_dump_with_manifest <url> <dump-file> <manifest-file> <stderr-file>
pg_dump_with_manifest() {
  local url="$1" out="$2" manifest="$3" err="$4" snapshot="" line="" status=0
  local to_psql="" from_psql="" psql_pid=""
  coproc SNAP {
    psql --dbname="$url" --no-psqlrc --quiet --no-align --tuples-only --field-separator=$'\t' \
      --set ON_ERROR_STOP=1 2>>"$err"
  }
  # A client that fails immediately may already be gone, and bash then unsets SNAP.
  to_psql="${SNAP[1]-}"
  from_psql="${SNAP[0]-}"
  psql_pid="${SNAP_PID-}"
  if [ -z "$to_psql" ] || [ -z "$from_psql" ]; then
    stop_coproc "$psql_pid"
    return 1
  fi
  if ! printf '%s\n' "BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY;" "SELECT pg_export_snapshot();" 1>&"$to_psql" 2>/dev/null \
    || ! IFS= read -r -t 120 snapshot <&"$from_psql" \
    || [[ ! "$snapshot" =~ ^[0-9A-Fa-f-]+$ ]]; then
    kill "$psql_pid" 2>/dev/null
    stop_coproc "$psql_pid"
    return 1
  fi
  pg_dump --snapshot="$snapshot" --format=custom --compress=6 --no-owner --no-privileges \
    --dbname="$url" --file="$out" 2>>"$err" || status=1
  if [ "$status" = 0 ]; then
    if printf '%s;\n' "$PG_COUNT_SQL" "SELECT '__END__'" 1>&"$to_psql" 2>/dev/null; then
      : >"$manifest"
      while IFS= read -r -t 600 line <&"$from_psql"; do
        [ "$line" = "__END__" ] && break
        printf '%s\n' "$line" >>"$manifest"
      done
    fi
    [ "$line" = "__END__" ] || status=1
  fi
  if [ "$status" = 0 ]; then
    printf '%s\n' "COMMIT;" '\q' 1>&"$to_psql" 2>/dev/null || true
  else
    kill "$psql_pid" 2>/dev/null   # timeout or error: never wait on a client that may be blocked
  fi
  stop_coproc "$psql_pid"
  [ "$status" = 0 ] \
    && pg_restore --file=/dev/null "$out" 2>>"$err" \
    && valid_manifest "$manifest"
}

# Row counts taken from a mysqldump file written with --skip-extended-insert and --add-locks:
# one INSERT per row, and table data only between `LOCK TABLES <t> WRITE;` and `UNLOCK TABLES;`.
# Only those INSERTs count, so INSERT text inside a dumped routine never adds phantom rows.
# Quoted identifiers are parsed with doubled-backtick escaping. Tables without rows count as 0.
mysql_manifest_from_dump() {
  gunzip -c "$1" | awk '
    function ident(s, start,    i, c, out) {
      out = ""
      for (i = start; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "`") {
          if (substr(s, i + 1, 1) == "`") { out = out "`"; i++; continue }
          return out
        }
        out = out c
      }
      return ""
    }
    /^CREATE TABLE `/            { t = ident($0, 15); if (!(t in n)) n[t] = 0; next }
    /^LOCK TABLES `.*` WRITE;$/  { data = ident($0, 14); next }
    /^UNLOCK TABLES;$/           { data = ""; next }
    data != "" && index($0, "INSERT INTO `") == 1 {
      if (ident($0, 14) == data) n[data]++
    }
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

# Roles named in CREATE POLICY … TO … statements of a pg_restore SQL script. Roles are
# cluster-wide and not part of a database dump, so a restore onto a fresh server fails with
# "role … does not exist" unless they are created first. Prints one role name per line.
pg_policy_roles() {
  awk '/^CREATE POLICY / {stmt = ""; inpol = 1}
       inpol {stmt = stmt " " $0; if ($0 ~ /;[[:space:]]*$/) {print stmt; inpol = 0}}' "$1" \
    | sed -E 's/ (USING|WITH CHECK) .*$//; s/;.*$//' \
    | sed -nE 's/.* TO (.*)$/\1/p' \
    | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^"(.*)"$/\1/' \
    | grep -vE '^(public|PUBLIC|CURRENT_USER|SESSION_USER|CURRENT_ROLE)?$' | LC_ALL=C sort -u
}

# Create every policy role the script needs that the target server lacks, as NOLOGIN roles.
#   ensure_policy_roles <restore.sql> <database-url>
ensure_policy_roles() {
  local role
  while IFS= read -r role; do
    [ -n "$role" ] || continue
    psql --dbname="$2" --no-psqlrc --quiet --set ON_ERROR_STOP=1 --set role="$role" <<'SQL' || return 1
SELECT format('CREATE ROLE %I NOLOGIN', :'role') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role') \gexec
SQL
    echo "ensured role $role"
  done < <(pg_policy_roles "$1")
}
