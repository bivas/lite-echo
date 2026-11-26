"""`liteecho fetch-models --from DIR`: import models from a local folder."""
import json

import pytest

import liteecho.fetch as fetch
from liteecho.fetch import FetchError, import_models, main
from test_fetch import FAKE_FILES, fake_expected  # noqa: F401

SUBDIRS = {"whisper": ("models", "precise"), "pyannote": ("pyannote",)}


@pytest.fixture
def models_folder(tmp_path):
    root = tmp_path / "src-models"
    for kind, files in FAKE_FILES.items():
        base = root.joinpath(*SUBDIRS[kind])
        for rel, data in files.items():
            p = base / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
    return root


def _leftovers(dest):
    return sorted(p.name for p in dest.iterdir() if p.name.startswith("."))


def test_import_success(tmp_path, fake_expected, models_folder):
    dest = tmp_path / "dest"
    result = import_models(models_folder, dest=dest, log=lambda m: None)
    assert set(result) == {"whisper", "pyannote"}
    for kind, files in FAKE_FILES.items():
        for rel, data in files.items():
            assert (result[kind] / rel).read_bytes() == data
        assert fetch.verify(kind, result[kind]) == []
    assert _leftovers(dest) == []


def test_import_sha_mismatch_rejected_and_cleaned_up(tmp_path, fake_expected, models_folder):
    (models_folder / "models" / "precise" / "model.bin").write_bytes(b"weights-X")  # same size, bad hash
    dest = tmp_path / "dest"
    with pytest.raises(FetchError, match="sha256"):
        import_models(models_folder, dest=dest, kinds=["whisper"], log=lambda m: None)
    assert list(dest.iterdir()) == []


def test_import_size_mismatch_rejected(tmp_path, fake_expected, models_folder):
    (models_folder / "pyannote" / "config.yaml").write_bytes(b"short")
    dest = tmp_path / "dest"
    with pytest.raises(FetchError, match="size"):
        import_models(models_folder, dest=dest, kinds=["pyannote"], log=lambda m: None)
    assert list(dest.iterdir()) == []


def test_bad_import_keeps_existing_good_model(tmp_path, fake_expected, models_folder):
    dest = tmp_path / "dest"
    import_models(models_folder, dest=dest, log=lambda m: None)
    (models_folder / "models" / "precise" / "config.json").write_bytes(b"XX")
    with pytest.raises(FetchError):
        import_models(models_folder, dest=dest, force=True, kinds=["whisper"], log=lambda m: None)
    assert fetch.verify("whisper", dest / "faster-whisper-large-v3-turbo") == []
    assert _leftovers(dest) == []


def test_missing_files_named_in_error(tmp_path, fake_expected, models_folder):
    (models_folder / "models" / "precise" / "model.bin").unlink()
    (models_folder / "pyannote" / "plda" / "plda.npz").unlink()
    dest = tmp_path / "dest"
    with pytest.raises(FetchError) as exc:
        import_models(models_folder, dest=dest, log=lambda m: None)
    msg = str(exc.value)
    assert str(models_folder / "models" / "precise" / "model.bin") in msg
    assert str(models_folder / "pyannote" / "plda" / "plda.npz") in msg
    assert not dest.exists() or list(dest.iterdir()) == []


def test_directory_in_place_of_file_counts_as_missing(tmp_path, fake_expected, models_folder):
    target = models_folder / "models" / "precise" / "config.json"
    target.unlink()
    target.mkdir()
    with pytest.raises(FetchError, match="config.json"):
        import_models(models_folder, dest=tmp_path / "dest", kinds=["whisper"], log=lambda m: None)


def test_only_limits_to_one_kind(tmp_path, fake_expected, models_folder):
    # pyannote files absent from the source: --only whisper must not care.
    import shutil
    shutil.rmtree(models_folder / "pyannote")
    dest = tmp_path / "dest"
    assert main(["--from", str(models_folder), "--dest", str(dest), "--only", "whisper"]) == 0
    assert (dest / "faster-whisper-large-v3-turbo").is_dir()
    assert not (dest / "speaker-diarization-community-1").exists()


def test_skip_when_present_and_force(tmp_path, fake_expected, models_folder):
    dest = tmp_path / "dest"
    logs = []
    import_models(models_folder, dest=dest, log=logs.append)
    logs.clear()
    import_models(models_folder, dest=dest, log=logs.append)
    assert all("skipping" in m for m in logs if "already present" in m) and any("skipping" in m for m in logs)
    logs.clear()
    import_models(models_folder, dest=dest, force=True, log=logs.append)
    assert any("importing" in m for m in logs)


def test_events_jsonl(tmp_path, fake_expected, models_folder, capsys):
    dest = tmp_path / "dest"
    assert main(["--from", str(models_folder), "--dest", str(dest), "--events", "jsonl"]) == 0
    events = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    stages = [e for e in events if e["type"] == "stage"]
    assert stages and all(e["stage"] == "download" and e["unit"] == "bytes" for e in stages)
    for kind in ("whisper", "pyannote"):
        mine = [e for e in stages if e["kind"] == kind]
        assert mine[0]["completed"] == 0
        assert mine[-1]["completed"] == mine[-1]["total"]
        assert all(e["completed"] < e["total"] for e in mine[:-1])
    assert events[-1]["type"] == "done"


def test_events_error_on_missing(tmp_path, fake_expected, models_folder, capsys):
    (models_folder / "pyannote" / "config.yaml").unlink()
    assert main(["--from", str(models_folder), "--dest", str(tmp_path / "d"), "--events", "jsonl"]) == 1
    events = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert events[-1]["type"] == "error" and "config.yaml" in events[-1]["message"]


def test_cli_missing_folder_exits_1(tmp_path, fake_expected, capsys):
    assert main(["--from", str(tmp_path / "nope"), "--dest", str(tmp_path / "d")]) == 1
    assert "error:" in capsys.readouterr().err
