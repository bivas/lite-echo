"""`liteecho rename-speakers FILE --map S1=Dana [--map S2=Avi ...] [--events jsonl]`.

Changes the display name of speakers in a LiteEcho transcript (format v1). The key is the
speaker ID (S1, S2, ...), which never changes; only the text of ``.speaker`` elements is
rewritten. Names are cleaned (see ``clean_name``), escaped and the file is replaced atomically.
"""
from __future__ import annotations

import argparse
import html
import os
import re
import sys
import tempfile
import unicodedata
from pathlib import Path

MAX_NAME = 60
_ID = re.compile(r"S[1-9][0-9]*")
_FORMAT_META = re.compile(r'<meta\s+name="liteecho:format"\s+content="([^"]*)"\s*/?>')
_SPEAKER_SPAN = re.compile(r'(<span class="speaker" data-speaker="(S[1-9][0-9]*)">)([^<]*)(</span>)')


class RenameError(Exception):
    pass


def clean_name(value: str) -> str:
    """Trim, drop control characters and < > " &, collapse whitespace, cut to 60 characters."""
    kept = "".join(ch for ch in value
                   if ch not in '<>"&' and not unicodedata.category(ch).startswith("C"))
    return " ".join(kept.split())[:MAX_NAME].strip()


def parse_map(items: list[str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for item in items:
        key, sep, value = item.partition("=")
        key = key.strip()
        if not sep or not _ID.fullmatch(key):
            raise RenameError(f"invalid --map {item!r}: expected ID=NAME with an ID like S1")
        name = clean_name(value)
        if not name:
            raise RenameError(f"invalid --map {item!r}: the name is empty after cleaning")
        out[key] = name
    return out


def rename_text(text: str, mapping: dict[str, str]) -> str:
    if not _FORMAT_META.search(text):
        raise RenameError("not a LiteEcho transcript (no liteecho:format meta tag)")
    present = set(m[2] for m in _SPEAKER_SPAN.finditer(text))
    unknown = sorted(set(mapping) - present, key=lambda s: int(s[1:]))
    if unknown:
        raise RenameError(f"speaker ID not in this transcript: {', '.join(unknown)}"
                          + (f" (it has {', '.join(sorted(present, key=lambda s: int(s[1:])))})" if present else ""))

    def sub(m: re.Match) -> str:
        sid = m[2]
        if sid not in mapping:
            return m[0]
        return m[1] + html.escape(mapping[sid], quote=True) + m[4]

    return _SPEAKER_SPAN.sub(sub, text)


def rename_file(path: str | os.PathLike, mapping: dict[str, str]) -> None:
    path = Path(path)
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        raise RenameError(f"not a LiteEcho transcript (not UTF-8 text): {path}") from None
    new = rename_text(text, mapping)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(new)
            f.flush()
            os.fsync(f.fileno())
        try:
            os.chmod(tmp, path.stat().st_mode & 0o7777)
        except OSError:
            pass
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="liteecho rename-speakers",
                                description="Rename speakers in a LiteEcho transcript.")
    p.add_argument("file", help="transcript .html written by LiteEcho")
    p.add_argument("--map", action="append", default=[], metavar="ID=NAME", required=True,
                   help="speaker ID and new display name, e.g. S1=Dana (repeatable)")
    p.add_argument("--events", choices=["jsonl"], default=None,
                   help="stdout carries only JSON event lines (done/error)")
    return p


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else list(argv)
    sink = None
    if any(a == "--events=jsonl" or (a == "--events" and argv[i + 1:i + 2] == ["jsonl"])
           for i, a in enumerate(argv)):
        from liteecho.events import EventSink
        sink = EventSink()
    parser = build_parser()
    if sink is not None:
        def _error(message: str):
            print(f"liteecho rename-speakers: error: {message}", file=sys.stderr)
            sink.error(message, None)
            raise SystemExit(2)
        parser.error = _error  # type: ignore[method-assign]
    args = parser.parse_args(argv)

    try:
        mapping = parse_map(args.map)
        path = Path(args.file).expanduser()
        if not path.is_file():
            raise RenameError(f"file not found: {args.file}")
        rename_file(path, mapping)
    except (RenameError, OSError) as exc:
        print(f"liteecho rename-speakers: error: {exc}", file=sys.stderr)
        if sink:
            sink.error(str(exc), None)
        return 1
    if sink:
        sink.done(output=str(path.resolve()))
    else:
        print(f"Renamed {len(mapping)} speaker(s) in {path}", file=sys.stderr)
    return 0
