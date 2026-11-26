"""Download (or import from a local folder) the models and verify them byte-for-byte.

The expected sha256/size values pin the exact model files LiteEcho is validated with, so a
successful fetch or import yields exactly the files the transcripts were validated against.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import os
import shutil
import sys
import tempfile
import threading
from pathlib import Path
from typing import Callable, Iterable

from huggingface_hub import snapshot_download
from huggingface_hub.errors import GatedRepoError, HfHubHTTPError

from liteecho.resources import (
    CACHE_PYANNOTE_SUBDIR,
    CACHE_WHISPER_SUBDIR,
    cache_dir,
)

WHISPER_REPO = "mobiuslabsgmbh/faster-whisper-large-v3-turbo"
# Latest commit of the repo ("Update README.md" on top of "Model files");
# all model files are byte-identical to the pinned files (git blob ids match).
WHISPER_REVISION = "0a363e9161cbc7ed1431c9597a8ceaf0c4f78fcf"

PYANNOTE_REPO = "pyannote/speaker-diarization-community-1"
# Gated repo: the anonymous commit list was not reachable, so the revision
# could not be confirmed. Files are pinned by sha256 instead (see EXPECTED).
PYANNOTE_REVISION = "main"

GATED_HELP = (
    "Accept the model terms at https://huggingface.co/pyannote/speaker-diarization-community-1, "
    "then run `hf auth login` or set the HF_TOKEN environment variable and retry."
)

# kind -> (repo, revision, cache subdir, {relpath: (sha256, size)})
_SPECS: dict[str, tuple[str, str, str, dict[str, tuple[str, int]]]] = {
    "whisper": (
        WHISPER_REPO,
        WHISPER_REVISION,
        CACHE_WHISPER_SUBDIR,
        {
            "model.bin": (
                "e76620f83d5f5b69efd3d87e3dc180c1bd21df9fbebacfd4335e5e1efcc018da",
                1617884929,
            ),
            "config.json": (
                "b0253ea6c0d3bea6b1e19e91a02acfd3b53f4467362efcb5a3e6b16c9b3a9b7e",
                2263,
            ),
            "tokenizer.json": (
                "297b13372ac43916285644fb9687add3cc62ee2a1adb60da3dc25cc94c1871fd",
                2710337,
            ),
            "vocabulary.json": (
                "c69260f2ab26d659b7c398f9a2b2b48ed0df16c3b47d7326782fd9cba71690c1",
                1068114,
            ),
            "preprocessor_config.json": (
                "7ccc62c6f2765af1f3b46c00c9b5894426835a05021c8b9c01eecb6dfb542711",
                340,
            ),
        },
    ),
    "pyannote": (
        PYANNOTE_REPO,
        PYANNOTE_REVISION,
        CACHE_PYANNOTE_SUBDIR,
        {
            "config.yaml": (
                "5ce2bfa9a938dc132cec1172592d65173cbb8f444ea1e4133f10f9391de155be",
                444,
            ),
            "segmentation/pytorch_model.bin": (
                "7ad24338d844fb95985486eb1a464e32d229f6d7a03c9abe60f978bacf3f816e",
                5906507,
            ),
            "embedding/pytorch_model.bin": (
                "6f10ff60898a1d185fa22e1d11e0bfa8a92efec811f11bca48cb8cafebefd929",
                26646242,
            ),
            "plda/plda.npz": (
                "9b77bcd840692710dd3496f62ecfeed8d8e5f002fd991b785079b244eab7d255",
                133852,
            ),
            "plda/xvec_transform.npz": (
                "325f1ce8e48f7e55e9c8aa47e05d2766b7c48c4b25b8de8dd751e7a4cc5fbe8f",
                134376,
            ),
        },
    ),
}

EXPECTED: dict[str, dict[str, tuple[str, int]]] = {k: v[3] for k, v in _SPECS.items()}
KINDS = tuple(_SPECS)


class FetchError(RuntimeError):
    """Raised when a model cannot be downloaded or fails verification."""


def sha256_file(path: Path | str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify(kind: str, folder: Path | str) -> list[str]:
    """Return human-readable mismatch/missing messages; an empty list means OK."""
    folder = Path(folder)
    problems: list[str] = []
    for relpath, (sha, size) in EXPECTED[kind].items():
        path = folder / relpath
        if not path.is_file():
            problems.append(f"{kind}: missing {relpath}")
            continue
        actual_size = path.stat().st_size
        if actual_size != size:
            problems.append(f"{kind}: {relpath} has size {actual_size}, expected {size}")
            continue
        actual_sha = sha256_file(path)
        if actual_sha != sha:
            problems.append(f"{kind}: {relpath} sha256 {actual_sha} does not match expected {sha}")
    return problems


def _translate_hub_error(kind: str, repo: str, exc: HfHubHTTPError) -> FetchError:
    status = getattr(getattr(exc, "response", None), "status_code", None)
    if isinstance(exc, GatedRepoError) or status in (401, 403):
        return FetchError(f"{kind}: access to {repo} denied (gated or unauthorized). {GATED_HELP}")
    return FetchError(f"{kind}: download of {repo} failed: {exc}")


def _downloaded_bytes(kind: str, root: Path) -> int:
    """Bytes of the expected files of ``kind`` under ``root``, finished or still `.incomplete`
    (huggingface_hub keeps in-flight downloads in ``root/.cache/huggingface/download``)."""
    total = 0
    partial_dir = root / ".cache" / "huggingface" / "download"
    for relpath, (_, size) in EXPECTED[kind].items():
        done = root / relpath
        try:
            if done.is_file():
                total += min(done.stat().st_size, size)
                continue
            parts = list((partial_dir / Path(relpath).parent).glob(Path(relpath).name + ".*.incomplete"))
            total += min(max((p.stat().st_size for p in parts), default=0), size)
        except OSError:  # file moved between listing and stat
            pass
    return total


class _ProgressPoller:
    """Polls the download folder and reports (completed, total) bytes for one kind."""

    def __init__(self, kind: str, root: Path, progress: Callable[[str, int, int], object],
                 interval: float = 0.2):
        self.kind, self.root, self.progress, self.interval = kind, root, progress, interval
        self.total = sum(size for _, size in EXPECTED[kind].values())
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        while not self._stop.wait(self.interval):
            # Never report "complete" from here: that is reserved for after verification.
            self.progress(self.kind, min(_downloaded_bytes(self.kind, self.root), self.total - 1),
                          self.total)

    def __enter__(self):
        self.progress(self.kind, 0, self.total)
        self._thread.start()
        return self

    def __exit__(self, *exc):
        self._stop.set()
        self._thread.join()


def fetch_models(
    dest: Path | None = None,
    token: str | None = None,
    force: bool = False,
    log: Callable[[str], object] = print,
    kinds: Iterable[str] | None = None,
    progress: Callable[[str, int, int], object] | None = None,
) -> dict[str, Path]:
    """Download and verify the models into ``dest`` (default: ``cache_dir()``).

    Returns a mapping of kind -> final model folder. A kind whose folder already
    verifies is skipped unless ``force`` is set. ``progress(kind, bytes_done, bytes_total)``
    is called while downloading; ``bytes_done == bytes_total`` only once the kind is verified.
    """
    dest = Path(dest) if dest is not None else Path(cache_dir())
    selected = tuple(kinds) if kinds is not None else KINDS
    for kind in selected:
        if kind not in _SPECS:
            raise FetchError(f"unknown model kind: {kind}")

    dest.mkdir(parents=True, exist_ok=True)
    result: dict[str, Path] = {}
    for kind in selected:
        repo, revision, subdir, _ = _SPECS[kind]
        final = dest / subdir
        if not force and not verify(kind, final):
            log(f"{kind}: already present and verified at {final}, skipping")
            if progress is not None:
                total = sum(size for _, size in EXPECTED[kind].values())
                progress(kind, total, total)
            result[kind] = final
            continue

        log(f"{kind}: downloading {repo}@{revision} to {final}")
        tmp = Path(tempfile.mkdtemp(prefix=f".{subdir}.tmp-", dir=dest))
        try:
            try:
                with (_ProgressPoller(kind, tmp, progress) if progress is not None
                      else contextlib.nullcontext()):
                    snapshot_download(
                        repo_id=repo,
                        revision=revision,
                        allow_patterns=list(EXPECTED[kind]),
                        local_dir=str(tmp),
                        token=token,
                    )
            except HfHubHTTPError as exc:
                raise _translate_hub_error(kind, repo, exc) from exc

            hub_meta = tmp / ".cache"
            if hub_meta.exists():
                shutil.rmtree(hub_meta, ignore_errors=True)

            problems = verify(kind, tmp)
            if problems:
                raise FetchError(
                    f"{kind}: verification failed for {repo}@{revision}:\n  " + "\n  ".join(problems)
                )

            if final.exists() or final.is_symlink():
                if final.is_dir() and not final.is_symlink():
                    shutil.rmtree(final)
                else:
                    final.unlink()
            os.replace(tmp, final)
        finally:
            if tmp.exists():
                shutil.rmtree(tmp, ignore_errors=True)

        log(f"{kind}: verified {final}")
        if progress is not None:
            total = sum(size for _, size in EXPECTED[kind].values())
            progress(kind, total, total)
        result[kind] = final
    return result


# Layout of a local models folder (see resources): kind -> subfolder holding that model.
_IMPORT_SUBDIRS = {"whisper": Path("models") / "precise", "pyannote": Path("pyannote")}


def _copy_verified(src: Path, dst: Path, sha: str, size: int, on_bytes: Callable[[int], object]) -> None:
    """Copy ``src`` to ``dst`` through a temp name, checking size and sha256; never leaves partial data."""
    tmp = dst.with_name(f".{dst.name}.part-{os.getpid()}")
    digest = hashlib.sha256()
    copied = 0
    try:
        dst.parent.mkdir(parents=True, exist_ok=True)
        with open(src, "rb") as fin, open(tmp, "wb") as fout:
            for chunk in iter(lambda: fin.read(1 << 20), b""):
                fout.write(chunk)
                digest.update(chunk)
                copied += len(chunk)
                on_bytes(len(chunk))
        if copied != size:
            raise FetchError(f"{src} has size {copied}, expected {size}")
        if digest.hexdigest() != sha:
            raise FetchError(f"{src} sha256 {digest.hexdigest()} does not match expected {sha}")
        os.replace(tmp, dst)
    finally:
        if tmp.exists():
            tmp.unlink()


def import_models(
    source: Path,
    dest: Path | None = None,
    force: bool = False,
    log: Callable[[str], object] = print,
    kinds: Iterable[str] | None = None,
    progress: Callable[[str, int, int], object] | None = None,
) -> dict[str, Path]:
    """Import the models from a local folder in the models folder layout into ``dest``.

    Each expected file is copied to a temp name, verified against ``EXPECTED`` and only then
    renamed into place, so a rejected file never leaves a half-written model behind.
    Returns kind -> final model folder.
    """
    source = Path(source).expanduser()
    dest = Path(dest) if dest is not None else Path(cache_dir())
    selected = tuple(kinds) if kinds is not None else KINDS
    for kind in selected:
        if kind not in _SPECS:
            raise FetchError(f"unknown model kind: {kind}")

    # Resolve every expected file first so a missing one is reported before anything is copied.
    sources: dict[str, dict[str, Path]] = {}
    missing: list[str] = []
    for kind in selected:
        root = source / _IMPORT_SUBDIRS[kind]
        sources[kind] = {}
        for relpath in EXPECTED[kind]:
            path = root / relpath
            if path.is_file():
                sources[kind][relpath] = path
            else:
                missing.append(str(path))
    if missing:
        raise FetchError("models folder is incomplete, missing files:\n  " + "\n  ".join(missing))

    dest.mkdir(parents=True, exist_ok=True)
    result: dict[str, Path] = {}
    for kind in selected:
        subdir = _SPECS[kind][2]
        final = dest / subdir
        total = sum(size for _, size in EXPECTED[kind].values())
        if not force and not verify(kind, final):
            log(f"{kind}: already present and verified at {final}, skipping")
            if progress is not None:
                progress(kind, total, total)
            result[kind] = final
            continue

        log(f"{kind}: importing from {source} to {final}")
        tmp = Path(tempfile.mkdtemp(prefix=f".{subdir}.tmp-", dir=dest))
        try:
            done = 0
            if progress is not None:
                progress(kind, 0, total)

            def on_bytes(n: int, _kind=kind, _total=total) -> None:
                nonlocal done
                done += n
                if progress is not None:
                    # "complete" is reserved for after verification
                    progress(_kind, min(done, _total - 1), _total)

            for relpath, (sha, size) in EXPECTED[kind].items():
                try:
                    _copy_verified(sources[kind][relpath], tmp / relpath, sha, size, on_bytes)
                except FetchError as exc:
                    raise FetchError(f"{kind}: verification failed for {relpath}: {exc}") from exc
                except OSError as exc:
                    raise FetchError(f"{kind}: could not copy {relpath}: {exc}") from exc

            problems = verify(kind, tmp)
            if problems:
                raise FetchError(f"{kind}: verification failed:\n  " + "\n  ".join(problems))

            if final.exists() or final.is_symlink():
                if final.is_dir() and not final.is_symlink():
                    shutil.rmtree(final)
                else:
                    final.unlink()
            os.replace(tmp, final)
        finally:
            if tmp.exists():
                shutil.rmtree(tmp, ignore_errors=True)

        log(f"{kind}: verified {final}")
        if progress is not None:
            progress(kind, total, total)
        result[kind] = final
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="liteecho fetch-models",
        description="Download the models from Hugging Face (or import them with --from) and verify them.",
    )
    parser.add_argument("--dest", type=Path, default=None, help="target directory (default: model cache dir)")
    parser.add_argument("--from", dest="source", type=Path, default=None, metavar="DIR",
                        help="import the models from a local folder in the models folder layout "
                             "(models/precise, pyannote/) instead of downloading")
    parser.add_argument("--force", action="store_true", help="re-download/re-import even if models verify")
    parser.add_argument("--only", choices=KINDS, default=None, help="fetch only one model set")
    parser.add_argument("--events", choices=["jsonl"], default=None,
                        help="print progress as JSON lines on stdout (the token is read from "
                             "HF_TOKEN or `hf auth login`, never from the command line)")
    return parser


def main(argv: list[str] | None = None) -> int:
    from liteecho.events import EventSink
    from liteecho.signals import Cancelled, sigterm_as_exception

    args = build_parser().parse_args(argv)
    sink = EventSink() if args.events else None

    def log(msg: str) -> None:
        print(msg, file=sys.stderr, flush=True)

    def progress(kind: str, completed: int, total: int) -> None:
        sink.stage("download", completed, total, "bytes", kind=kind)

    kinds = (args.only,) if args.only else None
    try:
        with sigterm_as_exception():
            if args.source is not None:
                import_models(args.source, dest=args.dest, force=args.force, log=log, kinds=kinds,
                              progress=progress if sink else None)
            else:
                fetch_models(dest=args.dest, force=args.force, log=log, kinds=kinds,
                             progress=progress if sink else None)
    except FetchError as exc:
        print(f"error: {exc}", file=sys.stderr)
        if sink:
            sink.error(str(exc), None)
        return 1
    except KeyboardInterrupt as exc:
        print("error: cancelled", file=sys.stderr)
        if sink:
            sink.error("cancelled", None)
        return 143 if isinstance(exc, Cancelled) else 130
    except Exception as exc:
        if not sink:
            raise
        sink.error_from_exception(exc)
        return 1
    if sink:
        sink.done()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
