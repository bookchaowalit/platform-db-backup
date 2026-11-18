"""Row-count manifests and the restore-script preamble fix-up."""

import tempfile
import unittest
from pathlib import Path

from shell import bash


class ValidManifestTests(unittest.TestCase):
    def check(self, text: str) -> bool:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "manifest.tsv"
            path.write_text(text, encoding="utf-8")
            return bash('valid_manifest "$1"', str(path)).returncode == 0

    def test_tab_separated_integer_counts_are_valid(self) -> None:
        self.assertTrue(self.check("public.users\t12\npublic.orders\t0\n"))

    def test_empty_manifest_is_valid(self) -> None:
        self.assertTrue(self.check(""))

    def test_failed_or_malformed_counts_are_invalid(self) -> None:
        for text in ("public.users\t\n", "public.users\tERROR\n", "public.users 12\n", "public.users\t-1\n"):
            with self.subTest(text=text):
                self.assertFalse(self.check(text))

    def test_missing_file_is_invalid(self) -> None:
        self.assertNotEqual(bash('valid_manifest "$1"', "/nonexistent/manifest").returncode, 0)


class StripPreambleSettingTests(unittest.TestCase):
    def test_removes_the_setting_only_before_the_first_statement(self) -> None:
        script = (
            "SET statement_timeout = 0;\n"
            "SET transaction_timeout = 0;\n"
            "CREATE TABLE notes (body text);\n"
            "COPY notes (body) FROM stdin;\n"
            "SET transaction_timeout = 0;\n"
            "\\.\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "restore.sql"
            path.write_text(script, encoding="utf-8")
            self.assertEqual(bash('strip_pg_preamble_setting "$1"', str(path)).returncode, 0)
            self.assertEqual(
                path.read_text(encoding="utf-8"),
                "SET statement_timeout = 0;\n"
                "CREATE TABLE notes (body text);\n"
                "COPY notes (body) FROM stdin;\n"
                "SET transaction_timeout = 0;\n"
                "\\.\n",
            )


class StripNeonColumnOptionsTests(unittest.TestCase):
    """Neon stores pg_attver in column options; vanilla PostgreSQL rejects it on restore."""

    def run_on(self, script: str) -> str:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "restore.sql"
            path.write_text(script, encoding="utf-8")
            self.assertEqual(bash('strip_neon_column_options "$1"', str(path)).returncode, 0)
            return path.read_text(encoding="utf-8")

    def test_drops_a_statement_that_only_sets_pg_attver(self) -> None:
        out = self.run_on(
            "CREATE TABLE platform.invitations (id uuid);\n"
            "ALTER TABLE ONLY platform.invitations ALTER COLUMN id SET (pg_attver=235371464);\n"
            "ALTER TABLE ONLY platform.invitations ADD CONSTRAINT p PRIMARY KEY (id);\n"
        )
        self.assertEqual(
            out,
            "CREATE TABLE platform.invitations (id uuid);\n"
            "ALTER TABLE ONLY platform.invitations ADD CONSTRAINT p PRIMARY KEY (id);\n",
        )

    def test_keeps_the_other_options_of_the_same_column(self) -> None:
        out = self.run_on(
            "ALTER TABLE ONLY s.t ALTER COLUMN c SET (n_distinct=-1, pg_attver=7);\n"
            "ALTER TABLE ONLY s.t ALTER COLUMN d SET (pg_attver=7, n_distinct=5);\n"
        )
        self.assertEqual(
            out,
            "ALTER TABLE ONLY s.t ALTER COLUMN c SET (n_distinct=-1);\n"
            "ALTER TABLE ONLY s.t ALTER COLUMN d SET (n_distinct=5);\n",
        )

    def test_handles_quoted_identifiers_with_spaces(self) -> None:
        out = self.run_on(
            'ALTER TABLE ONLY s."Order Items" ALTER COLUMN "Unit Price" SET (pg_attver=9);\n'
            'ALTER TABLE ONLY "a b"."c ""d""" ALTER COLUMN "x SET (y" SET (n_distinct=2, pg_attver=9);\n'
        )
        self.assertEqual(out, 'ALTER TABLE ONLY "a b"."c ""d""" ALTER COLUMN "x SET (y" SET (n_distinct=2);\n')

    def test_never_touches_a_dollar_quoted_routine_body(self) -> None:
        script = (
            "CREATE FUNCTION s.f() RETURNS void LANGUAGE sql AS $_$\n"
            "ALTER TABLE ONLY s.t ALTER COLUMN c SET (pg_attver=1);\n"
            "$_$;\n"
            "ALTER TABLE ONLY s.t ALTER COLUMN c SET (pg_attver=1);\n"
        )
        self.assertEqual(
            self.run_on(script),
            "CREATE FUNCTION s.f() RETURNS void LANGUAGE sql AS $_$\n"
            "ALTER TABLE ONLY s.t ALTER COLUMN c SET (pg_attver=1);\n"
            "$_$;\n",
        )

    def test_never_touches_copy_data(self) -> None:
        script = (
            "COPY s.notes (body) FROM stdin;\n"
            "ALTER TABLE ONLY x ALTER COLUMN y SET (pg_attver=1);\n"
            "\\.\n"
            "ALTER TABLE ONLY s.notes ALTER COLUMN body SET (pg_attver=1);\n"
        )
        self.assertEqual(
            self.run_on(script),
            "COPY s.notes (body) FROM stdin;\n"
            "ALTER TABLE ONLY x ALTER COLUMN y SET (pg_attver=1);\n"
            "\\.\n",
        )


if __name__ == "__main__":
    unittest.main()
