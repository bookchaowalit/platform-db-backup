"""URL helpers: percent-decoding, MySQL URL parsing and pointing a PostgreSQL URL at another database."""

import unittest

from shell import bash

PARSE = 'parse_mysql_url "$1" || exit 1; printf "%s|%s|%s|%s|%s" "$MYSQL_URL_USER" "$MYSQL_URL_PASSWORD" "$MYSQL_URL_HOST" "$MYSQL_URL_PORT" "$MYSQL_URL_DATABASE"'


def parse(url: str) -> str:
    result = bash(PARSE, url)
    assert result.returncode == 0, result.stderr
    return result.stdout


class UrlDecodeTests(unittest.TestCase):
    def test_decodes_once_and_keeps_plus_and_backslashes(self) -> None:
        self.assertEqual(bash('urldecode "$1"', "p%40ss+word%2541\\n").stdout, "p@ss+word%41\\n")


class ParseMysqlUrlTests(unittest.TestCase):
    def test_full_url_with_encoded_password(self) -> None:
        self.assertEqual(parse("mysql://app:s%3Acret%40x@db.example:3307/shop?ssl=true"), "app|s:cret@x|db.example|3307|shop")

    def test_missing_password_and_default_port(self) -> None:
        self.assertEqual(parse("mysql://app@db.example/shop"), "app||db.example|3306|shop")

    def test_bracketed_ipv6_host(self) -> None:
        self.assertEqual(parse("mysql://app:pw@[2001:db8::1]:3306/shop"), "app|pw|2001:db8::1|3306|shop")

    def test_rejects_other_schemes_and_missing_database(self) -> None:
        for url in ("postgres://app:pw@db/shop", "mysql://app:pw@db.example", "mysql://db.example/shop"):
            with self.subTest(url=url):
                self.assertEqual(bash('parse_mysql_url "$1"', url).returncode, 1)


class PgUrlWithDatabaseTests(unittest.TestCase):
    def test_replaces_the_path(self) -> None:
        out = bash('pg_url_with_database "$1" "$2"', "postgres://u:p@h:5432/app", "drill").stdout
        self.assertEqual(out, "postgres://u:p@h:5432/drill")

    def test_drops_dbname_parameters_even_percent_encoded_and_keeps_the_rest(self) -> None:
        url = "postgres://u:p@h/app?sslmode=require&dbname=other&%64bname=x&application_name=b"
        out = bash('pg_url_with_database "$1" "$2"', url, "drill").stdout
        self.assertEqual(out, "postgres://u:p@h/drill?sslmode=require&application_name=b")

    def test_no_query_left_when_only_dbname_was_there(self) -> None:
        out = bash('pg_url_with_database "$1" "$2"', "postgres://u:p@h/app?dbname=other", "drill").stdout
        self.assertEqual(out, "postgres://u:p@h/drill")


if __name__ == "__main__":
    unittest.main()
