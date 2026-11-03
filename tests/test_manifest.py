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


if __name__ == "__main__":
    unittest.main()
