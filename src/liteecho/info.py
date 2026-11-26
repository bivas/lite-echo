"""`liteecho engine-info --json [--verify]`: what the macOS app needs to know about the engine.

Uses importlib.metadata only (no heavy imports), so it returns well under a second without
--verify. The JSON shape is fixed by app/Sources/LiteEchoCore/EngineInfo.swift.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import sys
from importlib import metadata

PACKAGES = ("faster-whisper", "ctranslate2", "pyannote.audio", "torch", "torchaudio", "av", "numpy")


def _version(dist: str) -> str | None:
    try:
        return metadata.version(dist)
    except metadata.PackageNotFoundError:
        return None


def gather(models_dir: str | None = None, verify: bool = False,
           whisper_dir: str | None = None, pyannote_dir: str | None = None) -> dict:
    from liteecho import resources

    packages = {name: v for name in PACKAGES if (v := _version(name)) is not None}
    models: dict[str, dict] = {}
    own = {"whisper": whisper_dir, "pyannote": pyannote_dir}
    for kind in ("whisper", "pyannote"):
        loc = resources.resolve_model(kind, models_dir, own[kind])
        verified: bool | None = None
        problems = list(loc.problems)
        if verify and loc.path is not None:
            from liteecho.fetch import verify as verify_model
            found = verify_model(kind, loc.path)
            verified = not found
            if found:
                problems = found + [p for p in problems if "missing:" not in p]  # no duplicate missing-file lists
        models[kind] = {"source": loc.source, "path": str(loc.path) if loc.path else None,
                        "verified": verified, "problems": problems}
    from liteecho import languages, prompts
    tuned = set(prompts.load(resources.prompts_dir_for(models_dir)))
    return {
        "version": _version("liteecho") or "unknown",
        "python": platform.python_version(),
        "packages": packages,
        "models_dir": str(resources.cache_dir()),
        "models": models,
        "languages": languages.catalog(tuned),
    }


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="liteecho engine-info",
                                description="Print engine, library and model information as JSON.")
    p.add_argument("--json", action="store_true", help="print the information as one JSON object (default)")
    p.add_argument("--verify", action="store_true",
                   help="checksum the model files (a few seconds) and set `verified`")
    p.add_argument("--models-dir", default=os.environ.get("LITEECHO_MODELS") or None,
                   help="models folder in the models folder layout (models/precise, pyannote/) (default: $LITEECHO_MODELS)")
    p.add_argument("--whisper-dir", default=os.environ.get("LITEECHO_WHISPER_DIR") or None,
                   help="the whisper model's own folder (model.bin, config.json, ...); "
                        "overrides --models-dir (default: $LITEECHO_WHISPER_DIR)")
    p.add_argument("--pyannote-dir", default=os.environ.get("LITEECHO_PYANNOTE_DIR") or None,
                   help="the pyannote model's own folder (config.yaml, segmentation/, ...); "
                        "overrides --models-dir (default: $LITEECHO_PYANNOTE_DIR)")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    sys.stdout.write(json.dumps(gather(args.models_dir, args.verify, args.whisper_dir, args.pyannote_dir), ensure_ascii=False) + "\n")
    sys.stdout.flush()
    return 0
