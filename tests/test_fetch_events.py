"""`fetch-models --events jsonl` with a fake snapshot_download (reuses test_fetch fixtures)."""
import json
from pathlib import Path

from huggingface_hub.errors import GatedRepoError

import liteecho.fetch as fetch
from liteecho.fetch import fetch_models, main
from test_fetch import FAKE_FILES, _FakeResponse, fake_expected, fake_hub, source_dirs  # noqa: F401


def _events(capsys):
    return [json.loads(x) for x in capsys.readouterr().out.splitlines()]


def test_main_emits_download_events_per_kind_then_done(tmp_path, fake_expected, fake_hub, capsys):
    assert main(["--dest", str(tmp_path / "m"), "--events", "jsonl"]) == 0
    ev = _events(capsys)
    assert ev[-1] == {"type": "done"}
    stages = [e for e in ev if e["type"] == "stage"]
    for kind in ("whisper", "pyannote"):
        mine = [e for e in stages if e["kind"] == kind]
        total = sum(len(d) for d in FAKE_FILES[kind].values())
        assert mine[0]["completed"] == 0 and mine[-1]["completed"] == total
        assert all(e["stage"] == "download" and e["unit"] == "bytes" and e["total"] == total for e in mine)
        assert [e["completed"] for e in mine] == sorted(e["completed"] for e in mine)
        assert sum(1 for e in mine if e["completed"] == e["total"]) == 1


def test_skipped_kind_still_reports_completion(tmp_path, fake_expected, fake_hub, capsys):
    dest = tmp_path / "m"
    fetch_models(dest=dest, log=lambda m: None)
    capsys.readouterr()
    assert main(["--dest", str(dest), "--events", "jsonl", "--only", "whisper"]) == 0
    ev = _events(capsys)
    assert [e["kind"] for e in ev if e["type"] == "stage"] == ["whisper"]
    assert ev[-2]["completed"] == ev[-2]["total"]


def test_bytes_are_polled_during_download(tmp_path, fake_expected, monkeypatch):
    """A slow fake download leaves a `.incomplete` file; the poller must report its size."""
    import time
    seen = []

    def slow_download(repo_id, revision=None, allow_patterns=None, local_dir=None, token=None, **_):
        part = Path(local_dir) / ".cache" / "huggingface" / "download"
        part.mkdir(parents=True)
        (part / "model.bin.abc.incomplete").write_bytes(b"wei")
        time.sleep(0.6)
        (Path(local_dir) / "model.bin").write_bytes(b"weights-w")
        (Path(local_dir) / "config.json").write_bytes(b"{}")

    monkeypatch.setattr(fetch, "snapshot_download", slow_download)
    fetch_models(dest=tmp_path, kinds=["whisper"], log=lambda m: None,
                 progress=lambda k, c, t: seen.append((k, c, t)))
    assert seen[0] == ("whisper", 0, 11)
    assert any(c == 3 for _, c, _ in seen)
    assert seen[-1] == ("whisper", 11, 11)
    assert all(c < 11 for _, c, _ in seen[:-1])


def test_gated_repo_is_an_error_event(tmp_path, fake_expected, monkeypatch, capsys):
    def denied(**_):
        raise GatedRepoError("gated", response=_FakeResponse(401))

    monkeypatch.setattr(fetch, "snapshot_download", denied)
    assert main(["--dest", str(tmp_path), "--events", "jsonl", "--only", "pyannote"]) == 1
    ev = _events(capsys)
    assert ev[-1]["type"] == "error" and "gated or unauthorized" in ev[-1]["message"]
    assert "HF_TOKEN" in ev[-1]["message"]
    assert not any(e["type"] == "done" for e in ev)


def test_no_token_flag_exists():
    import pytest
    with pytest.raises(SystemExit):
        fetch.build_parser().parse_args(["--token", "x"])
    assert not any("token" in a.lower() for a in fetch.build_parser().format_help().split() if a.startswith("--"))


def test_without_events_stdout_is_silent(tmp_path, fake_expected, fake_hub, capsys):
    assert main(["--dest", str(tmp_path)]) == 0
    assert capsys.readouterr().out == ""
