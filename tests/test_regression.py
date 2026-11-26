"""Regression test: a real transcription must keep producing the same speakers and text.

Inputs: `$LITEECHO_REFERENCE_DIR/<stem>.m4a`. Expected output: `$LITEECHO_EXPECTED_DIR/<stem>.html`
(default `tests/.expected/`, gitignored because it is made from private recordings).

Create or refresh the expected file with
    LITEECHO_UPDATE_EXPECTED=1 uv run pytest -m integration tests/test_regression.py
then review it before relying on it.
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from liteecho.normalize import compare, drop_windows, extract_turns

REF_DIR = Path(os.environ.get("LITEECHO_REFERENCE_DIR", "/nonexistent/liteecho-reference"))
EXPECTED_DIR = Path(os.environ.get("LITEECHO_EXPECTED_DIR")
                    or Path(__file__).parent / ".expected").expanduser()
UPDATE = os.environ.get("LITEECHO_UPDATE_EXPECTED") == "1"

# Whisper's temperature fallback samples a few segments at random, so they differ between runs.
# From the first sampled segment on, the transcript is excluded on both sides; everything before
# it must match. Fail instead if that would hide more than this share of turns.
MAX_EXCLUDED_SHARE = 0.05
END_OF_TRANSCRIPT = 10**12  # ms

CASES = [
    "20261116 113541",
    pytest.param("20261116 143130", marks=pytest.mark.skip(reason="not enabled yet")),
]


def _models_available() -> bool:
    from liteecho.resources import ModelsNotFound, resolve
    try:
        resolve(os.environ.get("LITEECHO_MODELS") or None)
    except ModelsNotFound:
        return False
    return True


def _check_writable(folder: Path) -> None:
    documents = (Path.home() / "Documents").resolve()
    target = folder.resolve()
    if target == documents or documents in target.parents:
        pytest.fail(f"refusing to write expected transcripts under {documents}; "
                    "set LITEECHO_EXPECTED_DIR elsewhere")


@pytest.mark.integration
@pytest.mark.parametrize("stem", CASES)
def test_regression(stem, tmp_path):
    m4a = REF_DIR / f"{stem}.m4a"
    expected = EXPECTED_DIR / f"{stem}.html"
    if not m4a.exists():
        pytest.skip(f"reference audio missing: {m4a} (set LITEECHO_REFERENCE_DIR)")
    if not expected.exists() and not UPDATE:
        pytest.skip(f"expected transcript missing: {expected}. Create it with "
                    "LITEECHO_UPDATE_EXPECTED=1 uv run pytest -m integration tests/test_regression.py")
    if not _models_available():
        pytest.skip("no models: run `liteecho fetch-models` or `fetch-models --from DIR`")

    out = tmp_path / "out"
    out.mkdir()
    report = tmp_path / "sampled.json"
    cmd = [sys.executable, "-m", "liteecho", str(m4a), "--output-folder", str(out),
           "--language", "he", "--speakers", "auto", "--sampled-report", str(report)]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
    assert proc.returncode == 0, f"CLI failed:\n{proc.stdout[-2000:]}\n{proc.stderr[-4000:]}"
    actual_path = out / f"{stem}.html"
    assert actual_path.exists(), f"missing output; found {list(out.iterdir())}"
    actual = actual_path.read_text(encoding="utf-8")

    if UPDATE:
        _check_writable(EXPECTED_DIR)
        EXPECTED_DIR.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(actual_path, expected)
        pytest.skip(f"wrote {expected}; review it, then run again without LITEECHO_UPDATE_EXPECTED")

    expected_html = expected.read_text(encoding="utf-8")
    sampled = json.loads(report.read_text(encoding="utf-8"))
    # Whisper decodes sequentially: where a sampled segment ends decides where the next window
    # starts, so everything after the first sampled segment depends on the random draw too.
    windows = [(min(s["start_ms"] for s in sampled), END_OF_TRANSCRIPT)] if sampled else []
    for s in sampled:
        print(f"\nexcluded (sampled at T={s['temperature']}): {s['start_ms']}-{s['end_ms']} ms")
    for label, html_text in (("expected", expected_html), ("actual", actual)):
        turns = extract_turns(html_text)
        _, removed = drop_windows(turns, windows)
        assert removed <= MAX_EXCLUDED_SHARE * len(turns), (
            f"sampled segments would hide {removed}/{len(turns)} {label} turns; too many to ignore")

    diff = compare(expected_html, actual, exclude_windows=windows)
    if diff:
        (tmp_path / "actual.html").write_text(actual, encoding="utf-8")
        (tmp_path / "diff.txt").write_text(diff, encoding="utf-8")
        print("\n" + "\n".join(diff.splitlines()[:200]) + f"\n\nFull actual html + diff saved in: {tmp_path}")
    assert diff == "", f"transcript differs from the expected one (see {tmp_path})"
