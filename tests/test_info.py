import json
import subprocess
import sys
import time

import pytest

import liteecho.fetch as fetch
import liteecho.resources as res
from liteecho.info import PACKAGES, main

# EngineInfo.swift
MODEL_KEYS = {"source", "path", "verified", "problems"}
TOP_KEYS = {"version", "python", "packages", "models_dir", "models", "languages"}


def _make(root, names):
    for n in names:
        p = root / n
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x")


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("LITEECHO_CACHE", str(tmp_path / "cache"))
    monkeypatch.delenv("LITEECHO_MODELS", raising=False)
    monkeypatch.delenv("LITEECHO_WHISPER_DIR", raising=False)
    monkeypatch.delenv("LITEECHO_PYANNOTE_DIR", raising=False)
    return tmp_path


def run(capsys, *argv):
    assert main(list(argv)) == 0
    out = capsys.readouterr().out
    assert out.count("\n") == 1  # exactly one JSON object
    return json.loads(out)


def check_schema(info):
    assert set(info) == TOP_KEYS
    assert isinstance(info["version"], str) and isinstance(info["python"], str)
    assert set(info["packages"]) <= set(PACKAGES) and "numpy" in info["packages"]
    assert all(isinstance(v, str) for v in info["packages"].values())
    assert set(info["models"]) == {"whisper", "pyannote"}
    for m in info["models"].values():
        assert set(m) == MODEL_KEYS
        assert m["source"] in {"custom", "cache", "missing"}
        assert m["verified"] in (True, False, None)
        assert isinstance(m["problems"], list)
        assert (m["path"] is None) == (m["source"] == "missing")
    assert len(info["languages"]) == 100
    for lang in info["languages"]:
        assert set(lang) == {"code", "name", "native", "tuned"} and isinstance(lang["tuned"], bool)


def test_everything_missing(env, capsys):
    info = run(capsys, "--json", "--verify")
    check_schema(info)
    assert info["models_dir"] == str(env / "cache")
    for m in info["models"].values():
        assert m == {"source": "missing", "path": None, "verified": None, "problems": m["problems"]}
        assert m["problems"]


def test_partial_cache_without_verify_has_null_verified(env, capsys):
    _make(env / "cache" / res.CACHE_WHISPER_SUBDIR, res._WHISPER_FILES)
    info = run(capsys, "--json")
    check_schema(info)
    assert info["models"]["whisper"]["source"] == "cache"
    assert info["models"]["whisper"]["path"] == str(env / "cache" / res.CACHE_WHISPER_SUBDIR)
    assert info["models"]["pyannote"]["source"] == "missing"
    assert all(m["verified"] is None for m in info["models"].values())


def test_verify_true_and_false(env, capsys, monkeypatch):
    _make(env / "cache" / res.CACHE_WHISPER_SUBDIR, res._WHISPER_FILES)
    _make(env / "cache" / res.CACHE_PYANNOTE_SUBDIR, res._PYANNOTE_FILES)
    calls = []

    def fake_verify(kind, folder):
        calls.append((kind, str(folder)))
        return [] if kind == "whisper" else [f"{kind}: missing plda/plda.npz"]

    monkeypatch.setattr(fetch, "verify", fake_verify)
    info = run(capsys, "--json", "--verify")
    check_schema(info)
    assert info["models"]["whisper"]["verified"] is True
    assert info["models"]["pyannote"]["verified"] is False
    assert info["models"]["pyannote"]["problems"] == ["pyannote: missing plda/plda.npz"]
    assert len(calls) == 2


def test_custom_models_dir_is_never_mixed(env, capsys):
    custom = env / "custom"
    _make(custom / "models" / "precise", res._WHISPER_FILES)  # pyannote missing in custom
    _make(env / "cache" / res.CACHE_PYANNOTE_SUBDIR, res._PYANNOTE_FILES)  # must be ignored
    info = run(capsys, "--json", "--models-dir", str(custom))
    check_schema(info)
    assert info["models"]["whisper"]["source"] == "custom"
    assert info["models"]["pyannote"]["source"] == "missing"


def test_models_dir_from_environment(env, capsys, monkeypatch):
    custom = env / "custom"
    _make(custom / "pyannote", res._PYANNOTE_FILES)
    monkeypatch.setenv("LITEECHO_MODELS", str(custom))
    info = run(capsys, "--json")
    assert info["models"]["pyannote"]["source"] == "custom"


def test_resolve_model_agrees_with_resolve(env):
    _make(env / "cache" / res.CACHE_WHISPER_SUBDIR, res._WHISPER_FILES)
    _make(env / "cache" / res.CACHE_PYANNOTE_SUBDIR, res._PYANNOTE_FILES)
    paths = res.resolve()
    assert res.resolve_model("whisper").path == paths.whisper_dir
    assert res.resolve_model("pyannote").path == paths.pyannote_dir


def test_cli_dispatch_is_fast_and_light():
    t0 = time.time()
    r = subprocess.run([sys.executable, "-c",
                        "import sys; from liteecho.cli import main; main(['engine-info','--json']);"
                        "import json; heavy=[m for m in ('torch','huggingface_hub','av') if m in sys.modules];"
                        "sys.stderr.write(repr(heavy))"],
                       capture_output=True, text=True)
    assert r.returncode == 0
    check_schema(json.loads(r.stdout))
    assert r.stderr == "[]"
    assert time.time() - t0 < 1.0


def _fake_expected(monkeypatch):
    import hashlib
    exp = {}
    for kind, names in (("whisper", res._WHISPER_FILES), ("pyannote", res._PYANNOTE_FILES)):
        exp[kind] = {n: (hashlib.sha256(b"x").hexdigest(), 1) for n in names}
    monkeypatch.setattr(fetch, "EXPECTED", exp)


def test_whisper_dir_good_folder_verifies(env, capsys, monkeypatch):
    _fake_expected(monkeypatch)
    w = env / "mine"
    _make(w, res._WHISPER_FILES)
    info = run(capsys, "--json", "--verify", "--whisper-dir", str(w))
    check_schema(info)
    assert info["models"]["whisper"] == {"source": "custom", "path": str(w), "verified": True, "problems": []}
    assert info["models"]["pyannote"]["source"] == "missing"


def test_whisper_dir_incomplete_exits_zero_with_problems(env, capsys, monkeypatch):
    _fake_expected(monkeypatch)
    w = env / "mine"
    _make(w, res._WHISPER_FILES)
    (w / "model.bin").unlink()
    (w / "tokenizer.json").write_bytes(b"xxxx")  # wrong size
    info = run(capsys, "--json", "--verify", "--whisper-dir", str(w))
    check_schema(info)
    m = info["models"]["whisper"]
    assert m["source"] == "custom" and m["path"] == str(w) and m["verified"] is False
    text = "\n".join(m["problems"])
    assert "model.bin" in text and "tokenizer.json" in text


def test_incomplete_dir_without_verify_still_lists_missing(env, capsys):
    w = env / "empty"
    w.mkdir()
    info = run(capsys, "--json", "--pyannote-dir", str(w))
    check_schema(info)
    m = info["models"]["pyannote"]
    assert m["source"] == "custom" and m["verified"] is None
    assert "config.yaml" in "\n".join(m["problems"])


def test_nonexistent_dir_exits_zero(env, capsys):
    info = run(capsys, "--json", "--verify", "--whisper-dir", str(env / "nope"))
    assert info["models"]["whisper"]["source"] == "custom"
    assert info["models"]["whisper"]["verified"] is False
    assert info["models"]["whisper"]["problems"]


def test_per_model_dir_beats_models_dir_and_env(env, capsys, monkeypatch):
    models = env / "models"
    _make(models / "models" / "precise", res._WHISPER_FILES)
    _make(models / "pyannote", res._PYANNOTE_FILES)
    w = env / "w"
    _make(w, res._WHISPER_FILES)
    monkeypatch.setenv("LITEECHO_MODELS", str(models))
    monkeypatch.setenv("LITEECHO_WHISPER_DIR", str(w))
    info = run(capsys, "--json")
    assert info["models"]["whisper"]["path"] == str(w)
    assert info["models"]["pyannote"]["path"] == str(models / "pyannote")
    p = env / "p"
    _make(p, res._PYANNOTE_FILES)
    info = run(capsys, "--json", "--pyannote-dir", str(p))
    assert info["models"]["pyannote"]["path"] == str(p)
    assert info["models"]["whisper"]["path"] == str(w)


def test_pyannote_dir_env(env, capsys, monkeypatch):
    p = env / "p"
    _make(p, res._PYANNOTE_FILES)
    monkeypatch.setenv("LITEECHO_PYANNOTE_DIR", str(p))
    assert run(capsys, "--json")["models"]["pyannote"]["source"] == "custom"
