"""BACKUP_SCHEMA_<NAME>: one-schema dumps (schema name check and the scoped row-count query)."""

import unittest

from shell import bash


class SchemaNameTests(unittest.TestCase):
    def test_plain_lower_case_identifiers_only(self) -> None:
        for good in ("x_intel", "public", "_a1"):
            self.assertEqual(bash('valid_schema_name "$1"', good).returncode, 0, good)
        for bad in ("", "X_Intel", "a-b", "a;drop", "x' or '1", "1abc", "a b"):
            self.assertNotEqual(bash('valid_schema_name "$1"', bad).returncode, 0, bad)

    def test_a_bad_schema_never_reaches_pg_dump(self) -> None:
        result = bash('pg_dump() { echo CALLED; }; pg_dump_with_manifest u o m /dev/null "$1"; echo "rc=$?"', "a;b")
        self.assertNotIn("CALLED", result.stdout)
        self.assertIn("rc=64", result.stdout)


class CountSqlTests(unittest.TestCase):
    def test_without_a_schema_the_query_is_unchanged(self) -> None:
        self.assertEqual(bash('pg_count_sql_for ""').stdout, bash('printf "%s" "$PG_COUNT_SQL"').stdout)

    def test_a_schema_limits_the_count_to_that_schema(self) -> None:
        sql = bash('pg_count_sql_for "$1"', "x_intel").stdout
        self.assertIn("AND table_schema = 'x_intel'\nORDER BY 1", sql)
        self.assertEqual(sql.count("ORDER BY 1"), 1)


if __name__ == "__main__":
    unittest.main()
