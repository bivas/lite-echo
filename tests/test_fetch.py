"""Offline tests for liteecho.fetch (snapshot_download is faked)."""

from __future__ import annotations

import hashlib
import shutil
import sys
import types
from pathlib import Path

import pytest
from huggingface_hub.errors import GatedRepoError, HfHubHTTPError

# liteecho.resources is written by another agent; shim it for tests only if absent.
try:
    import liteecho.resources  # noqa: F401
except ImportError:
    _shim = types.ModuleType("liteecho.resources")
    _shim.cache_dir = lambda: Path("/nonexistent-cache")
    _shim.CACHE_WHISPER_SUBDIR = "faster-whisper-large-v3-turbo"
    _shim.CACHE_PYANNOTE_SUBDIR = "speaker-diarization-community-1"
    sys.modules["liteecho.resources"] = _shim

import liteecho.fetch as fetch  # noqa: E402
from liteecho.fetch import FetchError, fetch_models, main, sha256_file, verify  # noqa: E402

REAL_CACHE = Path.home() / "Library" / "Application Support" / "LiteEcho" / "models"
REAL_WHISPER = REAL_CACHE / "faster-whisper-large-v3-turbo"
REAL_PYANNOTE = REAL_CACHE / "speaker-diarization-community-1"

FAKE_FILES = {
    "whisper": {"model.bin": b"weights-w", "config.json": b"{}"},
    "pyannote": {"config.yaml": b"cfg: 1\n", "plda/plda.npz": b"plda-bytes"},
}


class _FakeResponse:
    """Minimal stand-in for an HTTP response; HfHubHTTPError only reads these attributes."""

    def __init__(self, status_code: int):
        self.status_code = status_code
        self.headers = {}
        self.text = ""
        self.url = "https://huggingface.co/x"
        self.content = b""
        self.request = None


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


@pytest.fixture
def fake_expected(monkeypatch):
    expected = {
        kind: {rel: (_sha(data), len(data)) for rel, data in files.items()}
        for kind, files in FAKE_FILES.items()
    }
    monkeypatch.setattr(fetch, "EXPECTED", expected)
    return expected


@pytest.fixture
def source_dirs(tmp_path):
    """Fake remote contents, one folder per kind, that snapshot_download copies from."""
    src = {}
    for kind, files in FAKE_FILES.items():
        root = tmp_path / "remote" / kind
        for rel, data in files.items():
            p = root / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
        src[kind] = root
    return src


@pytest.fixture
def fake_hub(monkeypatch, source_dirs):
    """Replace snapshot_download; records calls and copies only the allowed files."""
    calls = []
    repo_to_kind = {
        fetch.WHISPER_REPO: "whisper",
        fetch.PYANNOTE_REPO: "pyannote",
    }

    def fake_snapshot_download(repo_id, revision=None, allow_patterns=None, local_dir=None, token=None, **_):
        calls.append({"repo": repo_id, "revision": revision, "patterns": list(allow_patterns), "token": token})
        root = source_dirs[repo_to_kind[repo_id]]
        for rel in allow_patterns:
            src = root / rel
            if src.is_file():
                out = Path(local_dir) / rel
                out.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src, out)
        # mimic huggingface_hub's local_dir metadata folder
        (Path(local_dir) / ".cache").mkdir(exist_ok=True)
        return str(local_dir)

    monkeypatch.setattr(fetch, "snapshot_download", fake_snapshot_download)
    return calls


def _no_download(**_):
    raise AssertionError("snapshot_download should not have been called")


def test_sha256_file_matches_hashlib(tmp_path):
    p = tmp_path / "small.bin"
    p.write_bytes(b"hello world" * 1000)
    assert sha256_file(p) == hashlib.sha256(b"hello world" * 1000).hexdigest()


def test_sha256_file_streams_multiple_chunks(tmp_path):
    p = tmp_path / "big.bin"
    data = b"x" * (3 * (1 << 20) + 17)
    p.write_bytes(data)
    assert sha256_file(p) == _sha(data)


def test_verify_ok_and_messages(tmp_path, fake_expected):
    folder = tmp_path / "w"
    folder.mkdir()
    # missing everything
    msgs = verify("whisper", folder)
    assert any("missing model.bin" in m for m in msgs)
    assert any("missing config.json" in m for m in msgs)

    (folder / "model.bin").write_bytes(b"weights-w")
    (folder / "config.json").write_bytes(b"{}")
    assert verify("whisper", folder) == []

    # size mismatch
    (folder / "config.json").write_bytes(b"{}{}")
    msgs = verify("whisper", folder)
    assert len(msgs) == 1 and "config.json has size 4" in msgs[0]

    # same size, different content
    (folder / "config.json").write_bytes(b"[]")
    msgs = verify("whisper", folder)
    assert len(msgs) == 1 and "sha256" in msgs[0] and "config.json" in msgs[0]


def test_skip_when_valid(tmp_path, fake_expected, monkeypatch):
    dest = tmp_path / "dest"
    final = dest / fetch._SPECS["whisper"][2]
    final.mkdir(parents=True)
    for rel, data in FAKE_FILES["whisper"].items():
        (final / rel).write_bytes(data)
    monkeypatch.setattr(fetch, "snapshot_download", _no_download)

    logs = []
    result = fetch_models(dest=dest, kinds=("whisper",), log=logs.append)
    assert result == {"whisper": final}
    assert any("skipping" in m for m in logs)


def test_force_redownloads(tmp_path, fake_expected, fake_hub):
    dest = tmp_path / "dest"
    final = dest / fetch._SPECS["whisper"][2]
    final.mkdir(parents=True)
    for rel, data in FAKE_FILES["whisper"].items():
        (final / rel).write_bytes(data)

    fetch_models(dest=dest, kinds=("whisper",), force=True, log=lambda m: None)
    assert len(fake_hub) == 1
    assert fake_hub[0]["repo"] == fetch.WHISPER_REPO
    assert fake_hub[0]["revision"] == fetch.WHISPER_REVISION
    assert sorted(fake_hub[0]["patterns"]) == sorted(FAKE_FILES["whisper"])
    assert (final / "model.bin").read_bytes() == b"weights-w"
    # hub metadata folder is not kept, and no temp dirs remain
    assert not (final / ".cache").exists()
    assert sorted(p.name for p in dest.iterdir()) == [fetch._SPECS["whisper"][2]]


def test_fresh_download_installs_and_verifies(tmp_path, fake_expected, fake_hub):
    dest = tmp_path / "dest"
    result = fetch_models(dest=dest, log=lambda m: None)
    assert set(result) == {"whisper", "pyannote"}
    for kind, folder in result.items():
        assert folder == dest / fetch._SPECS[kind][2]
        assert verify(kind, folder) == []
    assert {c["repo"] for c in fake_hub} == {fetch.WHISPER_REPO, fetch.PYANNOTE_REPO}


def test_checksum_mismatch_raises_and_leaves_nothing(tmp_path, fake_expected, fake_hub, source_dirs):
    # corrupt the remote copy of model.bin, keeping the size identical
    (source_dirs["whisper"] / "model.bin").write_bytes(b"weights-X")
    dest = tmp_path / "dest"
    with pytest.raises(FetchError, match="verification failed") as info:
        fetch_models(dest=dest, kinds=("whisper",), log=lambda m: None)
    assert "model.bin" in str(info.value)
    assert list(dest.iterdir()) == []


def test_gated_error_is_translated(tmp_path, fake_expected, monkeypatch):
    response = _FakeResponse(401)

    def gated(**_):
        raise GatedRepoError("gated", response=response)

    monkeypatch.setattr(fetch, "snapshot_download", gated)
    dest = tmp_path / "dest"
    with pytest.raises(FetchError) as info:
        fetch_models(dest=dest, kinds=("pyannote",), log=lambda m: None)
    msg = str(info.value)
    assert "https://huggingface.co/pyannote/speaker-diarization-community-1" in msg
    assert "hf auth login" in msg and "HF_TOKEN" in msg
    assert list(dest.iterdir()) == []


def test_unauthorized_http_error_is_translated(tmp_path, fake_expected, monkeypatch):
    response = _FakeResponse(403)

    def forbidden(**_):
        raise HfHubHTTPError("forbidden", response=response)

    monkeypatch.setattr(fetch, "snapshot_download", forbidden)
    with pytest.raises(FetchError, match="HF_TOKEN"):
        fetch_models(dest=tmp_path / "dest", kinds=("pyannote",), log=lambda m: None)


def test_other_http_error_is_wrapped(tmp_path, fake_expected, monkeypatch):
    response = _FakeResponse(500)

    def boom(**_):
        raise HfHubHTTPError("server exploded", response=response)

    monkeypatch.setattr(fetch, "snapshot_download", boom)
    with pytest.raises(FetchError, match="download of"):
        fetch_models(dest=tmp_path / "dest", kinds=("whisper",), log=lambda m: None)


def test_default_dest_uses_cache_dir(tmp_path, fake_expected, fake_hub, monkeypatch):
    target = tmp_path / "cache"
    monkeypatch.setattr(fetch, "cache_dir", lambda: target)
    result = fetch_models(log=lambda m: None, kinds=("pyannote",))
    assert result["pyannote"] == target / fetch._SPECS["pyannote"][2]


def test_main_only_selects_one_kind(tmp_path, fake_expected, fake_hub, capsys):
    dest = tmp_path / "dest"
    rc = main(["--dest", str(dest), "--only", "pyannote"])
    assert rc == 0
    assert [c["repo"] for c in fake_hub] == [fetch.PYANNOTE_REPO]
    assert not (dest / fetch._SPECS["whisper"][2]).exists()
    err = capsys.readouterr().err
    assert "pyannote" in err


def test_main_rejects_unknown_only(capsys):
    with pytest.raises(SystemExit):
        main(["--only", "nope"])


def test_main_returns_1_on_failure(tmp_path, fake_expected, monkeypatch, capsys):
    response = _FakeResponse(401)

    def gated(**_):
        raise GatedRepoError("gated", response=response)

    monkeypatch.setattr(fetch, "snapshot_download", gated)
    rc = main(["--dest", str(tmp_path / "dest"), "--only", "pyannote"])
    assert rc == 1
    err = capsys.readouterr().err
    error_lines = [line for line in err.splitlines() if line.startswith("error: ")]
    assert len(error_lines) == 1 and "HF_TOKEN" in error_lines[0]


def test_main_force_flag_passed_through(tmp_path, fake_expected, fake_hub):
    dest = tmp_path / "dest"
    assert main(["--dest", str(dest), "--only", "whisper"]) == 0
    assert main(["--dest", str(dest), "--only", "whisper"]) == 0
    assert len(fake_hub) == 1  # second run skipped
    assert main(["--dest", str(dest), "--only", "whisper", "--force"]) == 0
    assert len(fake_hub) == 2


@pytest.mark.skipif(not (REAL_WHISPER.exists() and REAL_PYANNOTE.exists()), reason="models not in the default cache")
def test_expected_matches_cached_models():
    assert verify("whisper", REAL_WHISPER) == []
    assert verify("pyannote", REAL_PYANNOTE) == []
