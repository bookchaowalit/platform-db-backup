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
