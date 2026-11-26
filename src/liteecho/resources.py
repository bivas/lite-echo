"""Locate the model files LiteEcho needs.

Lookup order (see ``resolve``):

0. A per-model folder (``--whisper-dir`` / ``$LITEECHO_WHISPER_DIR``, ``--pyannote-dir`` /
   ``$LITEECHO_PYANNOTE_DIR``): the model's own folder. If it is incomplete, ``ModelsNotFound``
   (never a silent fallback). Wins over everything below, for that model only.
1. An explicit ``models_dir`` (``--models-dir`` / ``$LITEECHO_MODELS``) using the models folder
   layout (``models/precise`` for whisper, ``pyannote`` for diarization). If it is incomplete,
   ``ModelsNotFound``.
2. The LiteEcho cache (``cache_dir()``) with ``CACHE_WHISPER_SUBDIR`` and ``CACHE_PYANNOTE_SUBDIR``.

Prompts (``prompts.yml``) come from the vendored copy in ``assets/prompts`` unless a models folder has
``prompts/prompts.yml``.
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from importlib import resources
from pathlib import Path

CACHE_WHISPER_SUBDIR = "faster-whisper-large-v3-turbo"
CACHE_PYANNOTE_SUBDIR = "speaker-diarization-community-1"

# Files that must exist for a folder to count as a usable model directory.
_WHISPER_FILES = ("model.bin", "config.json", "tokenizer.json")
_PYANNOTE_FILES = (
    "config.yaml",
    "segmentation/pytorch_model.bin",
    "embedding/pytorch_model.bin",
    "plda/plda.npz",
    "plda/xvec_transform.npz",
)

_SOURCE_CACHE = "cache"
_SOURCE_CUSTOM = "custom"

_FETCH_HINT = (
    "Fix one of:\n"
    "  - run `liteecho fetch-models` (needs a Hugging Face token, and you must accept the terms at\n"
    "    https://huggingface.co/pyannote/speaker-diarization-community-1)\n"
    "  - import them from a local folder: `liteecho fetch-models --from DIR`\n"
    "  - pass --models-dir /path/to/models (or set $LITEECHO_MODELS), or per model\n"
    "    --whisper-dir DIR / --pyannote-dir DIR (or $LITEECHO_WHISPER_DIR / $LITEECHO_PYANNOTE_DIR)"
)


class ModelsNotFound(RuntimeError):
    """Required model files could not be located."""


@dataclass(frozen=True)
class ModelPaths:
    whisper_dir: Path   # folder with faster-whisper model.bin, config.json, tokenizer.json ...
    pyannote_dir: Path  # folder with config.yaml, segmentation/, embedding/, plda/
    prompts_dir: Path   # folder with prompts.yml
    source: str         # "custom" | "cache"


def cache_dir() -> Path:
    """Directory where ``liteecho fetch-models`` stores models.

    macOS: Application Support, not Caches, which the system may purge (a re-download needs
    the Hugging Face token again). The macOS app uses the same folder.
    """
    env = os.environ.get("LITEECHO_CACHE")
    if env:
        return Path(env).expanduser()
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "LiteEcho" / "models"
    xdg = os.environ.get("XDG_CACHE_HOME")
    base = Path(xdg).expanduser() if xdg else Path.home() / ".cache"
    return base / "liteecho" / "models"


def package_prompts_dir() -> Path:
    """The prompt files vendored with the package (``assets/prompts``)."""
    return Path(str(resources.files("liteecho") / "assets" / "prompts"))


def prompts_dir_for(models_dir: str | os.PathLike | None = None) -> Path:
    """``models_dir/prompts`` if it has a ``prompts.yml``, else the vendored folder."""
    if models_dir is not None:
        mp = Path(models_dir).expanduser() / "prompts"
        if (mp / "prompts.yml").is_file():
            return mp
    return package_prompts_dir()


def _missing(root: Path, names: tuple[str, ...]) -> list[str]:
    return [n for n in names if not (root / n).is_file()]


def is_whisper_dir(p: Path) -> bool:
    return not _missing(p, _WHISPER_FILES)


def is_pyannote_dir(p: Path) -> bool:
    return not _missing(p, _PYANNOTE_FILES)


def _describe_missing(root: Path, names: tuple[str, ...]) -> str:
    return f"{root} (missing: {', '.join(_missing(root, names))})"


_KINDS = {
    # kind: (required files, check, models-dir subfolder, cache subfolder, flag)
    "whisper": (_WHISPER_FILES, is_whisper_dir, Path("models") / "precise", CACHE_WHISPER_SUBDIR, "--whisper-dir"),
    "pyannote": (_PYANNOTE_FILES, is_pyannote_dir, Path("pyannote"), CACHE_PYANNOTE_SUBDIR, "--pyannote-dir"),
}


@dataclass(frozen=True)
class ModelLocation:
    """Where one model resolves. ``source`` is "custom" | "cache" | "missing".

    A per-model folder that is incomplete still reports ``source == "custom"`` with its ``path``
    and the missing files in ``problems`` (so callers can show what is wrong with it).
    """
    source: str
    path: Path | None
    problems: tuple[str, ...] = ()
    explicit: bool = False  # chosen via a per-model dir


def resolve_model(kind: str, models_dir: str | os.PathLike | None = None,
                  model_dir: str | os.PathLike | None = None) -> ModelLocation:
    """Resolve one model ("whisper" or "pyannote"), never raising.

    Precedence: ``model_dir`` (the model's own folder), then ``models_dir`` (models folder
    layout), then the cache. Only the first one given is considered.
    A missing model has ``source == "missing"``, ``path is None`` and the reasons in ``problems``.
    """
    if kind not in _KINDS:
        raise ValueError(f"unknown model kind: {kind}")
    names, check, custom_sub, cache_sub, flag = _KINDS[kind]

    if model_dir is not None:
        folder = Path(model_dir).expanduser()
        if check(folder):
            return ModelLocation(_SOURCE_CUSTOM, folder, (), True)
        return ModelLocation(_SOURCE_CUSTOM, folder,
                             (f"{kind} model {_describe_missing(folder, names)}",), True)

    if models_dir is not None:
        folder = Path(models_dir).expanduser() / custom_sub
        if check(folder):
            return ModelLocation(_SOURCE_CUSTOM, folder)
        return ModelLocation("missing", None, (f"{kind} model {_describe_missing(folder, names)}",))

    cache_folder = cache_dir() / cache_sub
    if check(cache_folder):
        return ModelLocation(_SOURCE_CACHE, cache_folder)
    return ModelLocation("missing", None, (
        f"{kind} model not found in cache: {_describe_missing(cache_folder, names)}",
    ))


def resolve(models_dir: str | os.PathLike | None = None,
            whisper_dir: str | os.PathLike | None = None,
            pyannote_dir: str | os.PathLike | None = None) -> ModelPaths:
    """Find the whisper, pyannote and prompt locations. Raises ``ModelsNotFound``.

    Per model: its own dir, else ``models_dir``, else the cache.
    """
    locs = {k: resolve_model(k, models_dir, d)
            for k, d in (("whisper", whisper_dir), ("pyannote", pyannote_dir))}
    problems = []
    for kind, loc in locs.items():
        if loc.path is not None and not loc.problems:
            continue
        if loc.explicit:
            flag = _KINDS[kind][4]
            problems.append(f"{flag} {loc.path} is not a complete {kind} model folder: "
                            + loc.problems[0])
        else:
            problems.append(loc.problems[0])
    if problems:
        if models_dir is not None and any(not l.explicit for l in locs.values()):
            head = f"--models-dir {Path(models_dir).expanduser()} is not a complete models folder:\n"
            tail = ""
        else:
            head = "LiteEcho models were not found:\n"
            tail = ("\n" + _FETCH_HINT) if any(not l.explicit for l in locs.values()) else ""
        raise ModelsNotFound(head + "\n".join(f"  - {p}" for p in problems) + tail)
    prompts = prompts_dir_for(models_dir)
    source = _SOURCE_CUSTOM if any(l.source == _SOURCE_CUSTOM for l in locs.values()) else _SOURCE_CACHE
    return ModelPaths(locs["whisper"].path, locs["pyannote"].path, prompts, source)
