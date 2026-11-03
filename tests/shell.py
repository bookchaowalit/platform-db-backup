"""Run scripts/lib.sh functions in bash and capture their output (helpers for the tests)."""

from __future__ import annotations

import subprocess
from pathlib import Path

LIB = Path(__file__).resolve().parents[1] / "scripts" / "lib.sh"


def bash(script: str, *args: str) -> subprocess.CompletedProcess[str]:
    """Run `script` with lib.sh sourced; positional args are $1, $2, ... inside it."""
    return subprocess.run(
        ["bash", "-c", f'source "{LIB}"\n{script}', "bash", *args],
        capture_output=True,
        text=True,
        check=False,
    )
