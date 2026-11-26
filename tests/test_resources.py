import sys
from pathlib import Path

import pytest
import yaml

from liteecho import resources
from liteecho.resources import (
    CACHE_PYANNOTE_SUBDIR,
    CACHE_WHISPER_SUBDIR,
    ModelsNotFound,
    cache_dir,
    is_pyannote_dir,
    is_whisper_dir,
    package_prompts_dir,
    resolve,
)


def make_whisper(d: Path) -> Path:
    d.mkdir(parents=True, exist_ok=True)
    for name in ("model.bin", "config.json", "tokenizer.json"):
        (d / name).write_bytes(b"")
    return d


def make_pyannote(d: Path) -> Path:
    for name in (
        "config.yaml",
        "segmentation/pytorch_model.bin",
        "embedding/pytorch_model.bin",
        "plda/plda.npz",
        "plda/xvec_transform.npz",
    ):
        f = d / name
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_bytes(b"")
    return d


def make_resources(root: Path) -> Path:
    """A models folder: models/precise, pyannote, prompts."""
    make_whisper(root / "models" / "precise")
    make_pyannote(root / "pyannote")
    (root / "prompts").mkdir(parents=True, exist_ok=True)
    (root / "prompts" / "prompts.yml").write_bytes(b'"x": "1"\n')
    return root


@pytest.fixture
def env(tmp_path, monkeypatch):
    """Isolated cache location; returns (cache_models_dir, other_models_folder)."""
    cache = tmp_path / "cache"
    other = tmp_path / "other"
    monkeypatch.setenv("LITEECHO_CACHE", str(cache))
    return cache, other


# --- predicates -------------------------------------------------------------

def test_is_whisper_dir_requires_all_files(tmp_path):
    d = make_whisper(tmp_path / "w")
    assert is_whisper_dir(d)
    (d / "tokenizer.json").unlink()
    assert not is_whisper_dir(d)
    assert not is_whisper_dir(tmp_path / "missing")


def test_is_pyannote_dir_requires_all_files(tmp_path):
    d = make_pyannote(tmp_path / "p")
    assert is_pyannote_dir(d)
    (d / "plda" / "xvec_transform.npz").unlink()
    assert not is_pyannote_dir(d)
    assert not is_pyannote_dir(tmp_path / "missing")


def test_package_prompts_dir_contains_vendored_prompts():
    d = package_prompts_dir()
    assert (d / "prompts.yml").is_file()
    assert not (d / "prompt.yml").exists() and not (d / "prompt_nd.yml").exists()


# --- explicit models_dir (custom) --------------------------------------------

def test_custom_dir_with_prompts_uses_custom_prompts(tmp_path, env):
    root = make_resources(tmp_path / "res")
    paths = resolve(root)
    assert paths.whisper_dir == root / "models" / "precise"
    assert paths.pyannote_dir == root / "pyannote"
    assert paths.prompts_dir == root / "prompts"
    assert paths.source == "custom"


def test_custom_dir_without_prompts_falls_back_to_package(tmp_path, env):
    root = make_resources(tmp_path / "res")
    (root / "prompts" / "prompts.yml").unlink()
    paths = resolve(str(root))
    assert paths.prompts_dir == package_prompts_dir()
    assert paths.source == "custom"


def test_custom_dir_accepts_pathlike_and_str(tmp_path, env):
    root = make_resources(tmp_path / "res")
    assert resolve(root).source == "custom"
    assert resolve(str(root)).source == "custom"


def test_custom_dir_is_not_mixed_with_other_locations(tmp_path, env):
    # Cache is complete, but the explicit dir is incomplete: must raise, not fall through.
    cache, _ = env
    make_whisper(cache / CACHE_WHISPER_SUBDIR)
    make_pyannote(cache / CACHE_PYANNOTE_SUBDIR)
    root = tmp_path / "empty"
    root.mkdir()
    with pytest.raises(ModelsNotFound) as exc:
        resolve(root)
    msg = str(exc.value)
    assert str(root) in msg
    assert "whisper model" in msg
    assert "pyannote model" in msg
    assert "model.bin" in msg
    assert "config.yaml" in msg


def test_custom_dir_names_only_the_missing_part(tmp_path, env):
    root = make_resources(tmp_path / "res")
    (root / "pyannote" / "plda" / "plda.npz").unlink()
    with pytest.raises(ModelsNotFound) as exc:
        resolve(root)
    msg = str(exc.value)
    assert "pyannote model" in msg
    assert "plda/plda.npz" in msg
    assert "whisper model" not in msg


# --- cache ------------------------------------------------------------------

def test_cache_both_present(tmp_path, env):
    cache, _ = env
    w = make_whisper(cache / CACHE_WHISPER_SUBDIR)
    p = make_pyannote(cache / CACHE_PYANNOTE_SUBDIR)
    paths = resolve()
    assert paths.whisper_dir == w
    assert paths.pyannote_dir == p
    assert paths.prompts_dir == package_prompts_dir()
    assert paths.source == "cache"


def test_cache_is_used_when_no_models_dir_given(tmp_path, env):
    cache, other = env
    make_resources(other)  # a complete folder elsewhere is never consulted implicitly
    cw = make_whisper(cache / CACHE_WHISPER_SUBDIR)
    cp = make_pyannote(cache / CACHE_PYANNOTE_SUBDIR)
    paths = resolve()
    assert (paths.whisper_dir, paths.pyannote_dir, paths.source) == (cw, cp, "cache")


def test_explicit_models_dir_wins_over_cache(tmp_path, env):
    cache, _ = env
    make_whisper(cache / CACHE_WHISPER_SUBDIR)
    make_pyannote(cache / CACHE_PYANNOTE_SUBDIR)
    root = make_resources(tmp_path / "res")
    paths = resolve(root)
    assert paths.whisper_dir == root / "models" / "precise"
    assert paths.source == "custom"


def test_partial_cache_is_not_mixed_with_other_locations(tmp_path, env):
    cache, other = env
    make_whisper(cache / CACHE_WHISPER_SUBDIR)
    make_resources(other)
    with pytest.raises(ModelsNotFound) as exc:
        resolve()
    assert "pyannote model not found" in str(exc.value)


def test_no_app_fallback_or_mixed_source_left():
    assert not hasattr(resources, "_SOURCE_APP")
    assert not hasattr(resources, "_SOURCE_MIXED")


# --- nothing found ----------------------------------------------------------

def test_nothing_found_raises_with_help(tmp_path, env):
    with pytest.raises(ModelsNotFound) as exc:
        resolve()
    msg = str(exc.value)
    assert "liteecho fetch-models" in msg
    assert "huggingface.co/pyannote/speaker-diarization-community-1" in msg
    assert "fetch-models --from" in msg
    assert "--models-dir" in msg
    assert "$LITEECHO_MODELS" in msg
    assert "\n" in msg


def test_only_whisper_missing_raises(tmp_path, env):
    cache, _ = env
    make_pyannote(cache / CACHE_PYANNOTE_SUBDIR)
    with pytest.raises(ModelsNotFound) as exc:
        resolve()
    msg = str(exc.value)
    assert "whisper model not found" in msg
    assert "pyannote model not found" not in msg


def test_only_pyannote_missing_raises(tmp_path, env):
    cache, _ = env
    make_whisper(cache / CACHE_WHISPER_SUBDIR)
    with pytest.raises(ModelsNotFound) as exc:
        resolve()
    msg = str(exc.value)
    assert "pyannote model not found" in msg
    assert "whisper model not found" not in msg


def test_models_not_found_is_runtime_error():
    assert issubclass(ModelsNotFound, RuntimeError)


# --- cache_dir --------------------------------------------------------------

def test_cache_dir_env_override(monkeypatch, tmp_path):
    monkeypatch.setenv("LITEECHO_CACHE", str(tmp_path / "x"))
    monkeypatch.setattr(sys, "platform", "darwin")
    assert cache_dir() == tmp_path / "x"


def test_cache_dir_macos_default(monkeypatch, tmp_path):
    monkeypatch.delenv("LITEECHO_CACHE", raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "xdg"))
    monkeypatch.setattr(sys, "platform", "darwin")
    assert cache_dir() == tmp_path / "Library" / "Application Support" / "LiteEcho" / "models"


def test_cache_dir_linux_xdg(monkeypatch, tmp_path):
    monkeypatch.delenv("LITEECHO_CACHE", raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "xdg"))
    monkeypatch.setattr(sys, "platform", "linux")
    assert cache_dir() == tmp_path / "xdg" / "liteecho" / "models"


def test_cache_dir_linux_default(monkeypatch, tmp_path):
    monkeypatch.delenv("LITEECHO_CACHE", raising=False)
    monkeypatch.delenv("XDG_CACHE_HOME", raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr(sys, "platform", "linux")
    assert cache_dir() == tmp_path / ".cache" / "liteecho" / "models"


def test_cache_dir_empty_env_is_ignored(monkeypatch, tmp_path):
    monkeypatch.setenv("LITEECHO_CACHE", "")
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr(sys, "platform", "darwin")
    assert cache_dir() == tmp_path / "Library" / "Application Support" / "LiteEcho" / "models"


# --- vendored prompts -------------------------------------------------------

def test_vendored_prompts_parse_with_he_and_en():
    data = yaml.safe_load((package_prompts_dir() / "prompts.yml").read_text(encoding="utf-8"))
    assert isinstance(data, dict)
    assert all(isinstance(k, str) for k in data)  # codes are quoted ("no" is not a boolean)
    assert "he" in data
    assert "en" in data


# --- per-model dirs ---------------------------------------------------------

def test_whisper_dir_wins_over_models_dir_and_cache(env, tmp_path):
    cache, other = env
    make_whisper(cache / CACHE_WHISPER_SUBDIR)
    make_pyannote(cache / CACHE_PYANNOTE_SUBDIR)
    make_resources(other)
    w = make_whisper(tmp_path / "mine")
    paths = resolve(other, whisper_dir=w)
    assert paths.whisper_dir == w
    assert paths.pyannote_dir == other / "pyannote"
    assert paths.source == "custom"


def test_pyannote_dir_alone_falls_back_to_cache_for_whisper(env, tmp_path):
    cache, _ = env
    make_whisper(cache / CACHE_WHISPER_SUBDIR)
    p = make_pyannote(tmp_path / "mine")
    paths = resolve(pyannote_dir=p)
    assert paths.pyannote_dir == p
    assert paths.whisper_dir == cache / CACHE_WHISPER_SUBDIR


def test_both_dirs_need_no_cache_or_models_dir(env, tmp_path):
    w = make_whisper(tmp_path / "w")
    p = make_pyannote(tmp_path / "p")
    paths = resolve(whisper_dir=w, pyannote_dir=p)
    assert (paths.whisper_dir, paths.pyannote_dir) == (w, p)
    assert paths.prompts_dir == package_prompts_dir()


def test_incomplete_whisper_dir_errors_without_fallback(env, tmp_path):
    cache, other = env
    make_whisper(cache / CACHE_WHISPER_SUBDIR)  # complete cache must NOT be used
    make_pyannote(cache / CACHE_PYANNOTE_SUBDIR)
    w = make_whisper(tmp_path / "mine")
    (w / "model.bin").unlink()
    with pytest.raises(ModelsNotFound) as e:
        resolve(whisper_dir=w)
    msg = str(e.value)
    assert "--whisper-dir" in msg and "model.bin" in msg and str(w) in msg


def test_incomplete_pyannote_dir_names_missing_files(env, tmp_path):
    p = make_pyannote(tmp_path / "p")
    (p / "plda" / "plda.npz").unlink()
    with pytest.raises(ModelsNotFound) as e:
        resolve(pyannote_dir=p)
    assert "--pyannote-dir" in str(e.value) and "plda/plda.npz" in str(e.value)


def test_nonexistent_whisper_dir_errors(env, tmp_path):
    with pytest.raises(ModelsNotFound, match="--whisper-dir"):
        resolve(whisper_dir=tmp_path / "nope")


def test_resolve_model_per_model_dir_reports_custom_even_if_incomplete(env, tmp_path):
    w = tmp_path / "w"
    w.mkdir()
    loc = resources.resolve_model("whisper", None, w)
    assert loc.source == "custom" and loc.path == w
    assert any("model.bin" in p for p in loc.problems)
