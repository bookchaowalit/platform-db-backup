"""classify_dump_error maps client error output to a short category that carries no secrets."""

import tempfile
import unittest
from pathlib import Path

from shell import bash


def classify(text: str) -> str:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "err"
        path.write_text(text, encoding="utf-8")
        return bash('classify_dump_error "$1"', str(path)).stdout.strip()


class ClassifyDumpErrorTests(unittest.TestCase):
    def test_categories(self) -> None:
        cases = {
            "": "no error output",
            "pg_dump: error: permission denied for table secrets": "permission denied",
            'FATAL:  password authentication failed for user "app"': "authentication failed",
            "ERROR 1045 (28000): Access denied for user 'app'@'10.0.0.1'": "authentication failed",
            "could not connect to server: Connection refused": "connection failed",
            "ERROR 2005 (HY000): Unknown MySQL server host 'db'": "connection failed",
            "pg_dump: error: aborting because of server version mismatch": "client/server version mismatch",
            'ERROR:  relation "x" already exists': "object exists / missing",
            "invalid URI query parameter": "invalid connection URL, option or SQL",
            "something else entirely": "see a manual run for details",
        }
        for text, category in cases.items():
            with self.subTest(text=text):
                self.assertEqual(classify(text), category)

    def test_the_category_never_echoes_the_error_text(self) -> None:
        out = classify('FATAL:  password authentication failed for user "app-SENTINEL" from host db-SENTINEL')
        self.assertEqual(out, "authentication failed")
        self.assertNotIn("SENTINEL", out)

    def test_missing_file_counts_as_no_output(self) -> None:
        self.assertEqual(bash('classify_dump_error "$1"', "/nonexistent/err").stdout.strip(), "no error output")


if __name__ == "__main__":
    unittest.main()
