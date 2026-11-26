"""Read-only access to Apple's Voice Memos library (docs/transcript-format.md, "Voice Memos").

`liteecho voice-memos list --json [--library DIR]`
`liteecho voice-memos import ID [--library DIR] [--output-folder DIR] [transcribe options] [--events jsonl]`

Safety rules, all enforced here:

- Apple's files are never opened for writing. The database (`CloudRecordings.db` plus its `-wal`
  and `-shm`) is copied into a fresh temp dir and only the copy is opened, read-only
  (`mode=ro`). `immutable=1` is never used: it would ignore the WAL. The temp dir is removed.
- Column names come from `PRAGMA table_info` and are only used when they are in an allowlist of
  known names; nothing else is ever put into SQL.
- `ZPATH` is data. It must be a relative path without `..` whose resolved target (symlinks
  followed) stays inside the library; anything else is treated as "no local audio".
- No titles, paths or other recording data are logged.

Only the standard library is imported at module level.
"""
from __future__ import annotations

import os
import shutil
import sqlite3
import stat
import struct
import sys
import tempfile
import unicodedata
import urllib.parse
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

DEFAULT_LIBRARY = Path("~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings")
DEFAULT_OUTPUT = Path("~/Documents/LiteEcho Transcripts")
DB_NAME = "CloudRecordings.db"
CORE_DATA_EPOCH = 978307200  # 2001-01-01T00:00:00Z in Unix seconds

# Status codes (contract v1).
OK, NO_ACCESS, NO_LIBRARY, UNREADABLE = "ok", "no-access", "no-library", "unreadable"

RECORDING_TABLE = "ZCLOUDRECORDING"
FOLDER_TABLE = "ZFOLDER"
# Every column we may read. A column is selected only if it is in this set *and* the copy's
# PRAGMA table_info lists it (schemas drift between macOS versions).
RECORDING_COLUMNS = frozenset({
    "Z_PK", "ZUNIQUEID", "ZDATE", "ZDURATION", "ZLOCALDURATION", "ZPATH",
    "ZENCRYPTEDTITLE", "ZENCRYPTEDCUSTOMLABEL", "ZCUSTOMLABELFORSORTING", "ZCUSTOMLABEL",
    "ZFOLDER", "ZEVICTIONDATE", "ZTRASHEDDATE", "ZFLAGS", "ZSHAREDFLAGS",
})
FOLDER_COLUMNS = frozenset({"Z_PK", "ZUUID", "ZENCRYPTEDNAME", "ZNAME", "ZRANK"})
TITLE_COLUMNS = ("ZENCRYPTEDTITLE", "ZENCRYPTEDCUSTOMLABEL", "ZCUSTOMLABELFORSORTING", "ZCUSTOMLABEL")
DELETED_COLUMNS = ("ZEVICTIONDATE", "ZTRASHEDDATE")  # non-NULL = in Recently Deleted

# ZSHAREDFLAGS bit 0x02 = favourite. Reported by one source (OpenExtract, from the iOS 26.5 Core
# Data model) and not verified against a real macOS library, so treat it as best effort.
FAVORITE_BIT = 0x02
# The "has Apple transcript" ZFLAGS bit is disputed (0x08 on macOS 15.6.1 vs 0x400 in the iOS 26.5
# model), so it is not used. Instead the local audio file is probed for a `tsrp` atom; a memo
# without local audio reports False ("unknown").

MAX_TITLE = 200
MAX_FILE_STEM = 120


class LibraryError(Exception):
    def __init__(self, status: str, detail: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail


@dataclass
class Folder:
    id: str
    name: str
    rank: float = 0.0


@dataclass
class Memo:
    id: str
    title: str
    recorded: str | None           # ISO-8601 UTC, "...Z"
    recorded_ts: float | None      # Unix seconds
    duration_s: float
    folder_id: str | None
    folder_name: str | None
    favorite: bool
    local: bool
    apple_transcript: bool
    format: str
    audio_path: Path | None = field(default=None, repr=False)  # resolved, inside the library

    def to_json(self) -> dict:
        return {"id": self.id, "title": self.title, "recorded": self.recorded,
                "duration_s": self.duration_s, "folder_id": self.folder_id,
                "favorite": self.favorite, "local": self.local,
                "apple_transcript": self.apple_transcript, "format": self.format}


@dataclass
class Library:
    status: str
    detail: str
    folders: list[Folder] = field(default_factory=list)
    memos: list[Memo] = field(default_factory=list)

    def to_json(self) -> dict:
        return {"status": self.status, "detail": self.detail,
                "folders": [{"id": f.id, "name": f.name} for f in self.folders],
                "memos": [m.to_json() for m in self.memos]}


# --- library and database access --------------------------------------------------------------

def _oserror_status(exc: OSError) -> str:
    if isinstance(exc, PermissionError):
        return NO_ACCESS
    if isinstance(exc, (FileNotFoundError, NotADirectoryError)):
        return NO_LIBRARY
    return UNREADABLE


def check_library(library: Path) -> None:
    """Raise LibraryError unless the library folder exists and can be listed."""
    try:
        os.stat(library)
        os.listdir(library)
    except OSError as exc:
        status = _oserror_status(exc)
        raise LibraryError(status, {
            NO_ACCESS: "Reading the Voice Memos library was denied. Grant Full Disk Access to "
                       "LiteEcho (or to your terminal app for the CLI) in System Settings > "
                       "Privacy & Security > Full Disk Access.",
            NO_LIBRARY: "No Voice Memos library was found. Open Voice Memos once to create it.",
        }.get(status, f"The Voice Memos library can't be read ({type(exc).__name__}).")) from None


def _copy_db(library: Path, dest: Path) -> Path:
    """Copy the database and its sidecars back to back. Returns the copy's path."""
    src = library / DB_NAME
    copy = dest / DB_NAME
    shutil.copyfile(src, copy)  # reads only; raises PermissionError / FileNotFoundError
    for suffix in ("-wal", "-shm"):
        side = library / (DB_NAME + suffix)
        target = dest / (DB_NAME + suffix)
        try:
            shutil.copyfile(side, target)
        except FileNotFoundError:
            target.unlink(missing_ok=True)
    return copy


def _connect_ro(path: Path) -> sqlite3.Connection:
    uri = f"file:{urllib.parse.quote(str(path))}?mode=ro"
    return sqlite3.connect(uri, uri=True)


def _quick_check_ok(conn: sqlite3.Connection) -> bool:
    try:
        rows = conn.execute("PRAGMA quick_check").fetchall()
    except sqlite3.DatabaseError:
        return False
    return rows == [("ok",)]


def _columns(conn: sqlite3.Connection, table: str, allowed: frozenset[str]) -> list[str]:
    assert table in (RECORDING_TABLE, FOLDER_TABLE)  # constant table names only
    names = [r[1] for r in conn.execute(f"PRAGMA table_info({table})").fetchall()]
    return [n for n in names if n in allowed]


def _select(conn: sqlite3.Connection, table: str, allowed: frozenset[str]) -> list[dict]:
    cols = _columns(conn, table, allowed)
    if not cols:
        return []
    assert all(c in allowed for c in cols)
    sql = "SELECT " + ", ".join(f'"{c}"' for c in cols) + f" FROM {table}"
    return [dict(zip(cols, row)) for row in conn.execute(sql).fetchall()]


def read_tables(library: Path, attempts: int = 2) -> tuple[list[dict], list[dict]]:
    """(recording rows, folder rows) from a private copy of the database."""
    last = "the database copy failed its integrity check"
    for _ in range(attempts):
        tmp = tempfile.mkdtemp(prefix="liteecho_vm_")
        try:
            try:
                copy = _copy_db(library, Path(tmp))
            except OSError as exc:
                status = _oserror_status(exc)
                if status == NO_ACCESS:
                    raise LibraryError(NO_ACCESS, "Reading the Voice Memos database was denied. "
                                       "Grant Full Disk Access to LiteEcho (or to your terminal "
                                       "app for the CLI).") from None
                if status == NO_LIBRARY:
                    raise LibraryError(NO_LIBRARY, "The Voice Memos library has no database. "
                                       "Open Voice Memos once to create it.") from None
                raise LibraryError(UNREADABLE, f"Copying the Voice Memos database failed "
                                   f"({type(exc).__name__}).") from None
            conn = None
            try:
                conn = _connect_ro(copy)
                if not _quick_check_ok(conn):
                    continue  # torn copy (caught a write mid-flight): copy again
                tables = {r[0] for r in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
                if RECORDING_TABLE not in tables:
                    raise LibraryError(UNREADABLE, "The Voice Memos database has an unknown layout "
                                       "(no recordings table).")
                recs = _select(conn, RECORDING_TABLE, RECORDING_COLUMNS)
                if recs and "ZUNIQUEID" not in recs[0]:
                    raise LibraryError(UNREADABLE, "The Voice Memos database has an unknown layout "
                                       "(no recording id column).")
                folders = _select(conn, FOLDER_TABLE, FOLDER_COLUMNS) if FOLDER_TABLE in tables else []
                return recs, folders
            except sqlite3.DatabaseError as exc:
                last = f"the database copy can't be read ({type(exc).__name__})"
                continue
            finally:
                if conn is not None:
                    conn.close()
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    raise LibraryError(UNREADABLE, f"The Voice Memos database can't be read: {last}.")


# --- row interpretation -----------------------------------------------------------------------

def _num(value) -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _int(value) -> int:
    n = _num(value)
    return int(n) if n is not None else 0


def _text(value) -> str:
    if isinstance(value, bytes):
        value = value.decode("utf-8", "replace")
    if not isinstance(value, str):
        return ""
    kept = "".join(" " if unicodedata.category(ch).startswith("C") else ch for ch in value)
    return " ".join(kept.split())[:MAX_TITLE]


def _when(ts: float | None) -> tuple[str | None, float | None]:
    if ts is None:
        return None, None
    unix = ts + CORE_DATA_EPOCH
    try:
        dt = datetime.fromtimestamp(unix, tz=timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None, None
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ"), unix


def fallback_title(unix: float | None) -> str:
    if unix is None:
        return "Recording"
    return "Recording " + datetime.fromtimestamp(unix).strftime("%Y-%m-%d %H:%M")


def safe_audio_path(library: Path, zpath) -> Path | None:
    """The resolved audio file for ZPATH, or None if it is unsafe or not a usable local file.

    Rejected: empty, absolute, containing `..` or NUL, or resolving (symlinks followed) outside
    the library. Accepted only if it is a regular file with size > 0.
    """
    if isinstance(zpath, bytes):
        zpath = zpath.decode("utf-8", "replace")
    if not isinstance(zpath, str) or not zpath.strip() or "\x00" in zpath:
        return None
    rel = PurePosixPath(zpath)
    if rel.is_absolute() or zpath.startswith(("/", "\\", "~")) or ".." in rel.parts \
            or ".." in Path(zpath).parts:
        return None
    try:
        root = library.resolve()
        target = (root / rel).resolve()
        if not target.is_relative_to(root) or target == root:
            return None
        st = target.stat()
    except (OSError, ValueError, RuntimeError):
        return None
    if not stat.S_ISREG(st.st_mode) or st.st_size <= 0:
        return None
    return target


def audio_format(zpath) -> str:
    if isinstance(zpath, bytes):
        zpath = zpath.decode("utf-8", "replace")
    suffix = PurePosixPath(zpath).suffix.lower().lstrip(".") if isinstance(zpath, str) else ""
    return suffix


# --- MP4 / QuickTime atom probe for Apple's transcript ---------------------------------------

_CONTAINERS = {b"moov", b"trak", b"mdia", b"minf", b"udta", b"meta", b"edts", b"dinf", b"stbl"}
MAX_ATOMS = 4096
MAX_KEYS_BYTES = 64 * 1024


def has_tsrp(path: Path) -> bool:
    """True if the file has a `tsrp` atom (m4a: moov/trak/udta/tsrp) or a metadata key containing
    `tsrp` (qta: `com.apple.VoiceMemos.tsrp`). Reads box headers only (and at most 64 KB of a
    `keys` box); never the audio. Any parse problem means False."""
    try:
        size = path.stat().st_size
        with open(path, "rb") as fh:
            budget = [MAX_ATOMS]
            return _scan(fh, 0, size, 0, budget)
    except (OSError, struct.error, ValueError):
        return False


def _scan(fh, start: int, end: int, depth: int, budget: list[int]) -> bool:
    pos = start
    while pos + 8 <= end:
        budget[0] -= 1
        if budget[0] < 0:
            return False
        fh.seek(pos)
        head = fh.read(8)
        if len(head) < 8:
            return False
        size, kind = struct.unpack(">I4s", head)
        hdr = 8
        if size == 1:
            big = fh.read(8)
            if len(big) < 8:
                return False
            size = struct.unpack(">Q", big)[0]
            hdr = 16
        elif size == 0:
            size = end - pos
        if size < hdr or pos + size > end:
            return False
        if kind == b"tsrp":
            return True
        if kind == b"keys":
            fh.seek(pos + hdr)
            if b"tsrp" in fh.read(min(size - hdr, MAX_KEYS_BYTES)):
                return True
        elif kind in _CONTAINERS and depth < 8:
            inner = pos + hdr
            if kind == b"meta":
                # ISO `meta` is a full box (4 bytes version/flags); QuickTime's is not.
                fh.seek(inner)
                peek = fh.read(8)
                if len(peek) == 8 and peek[4:8] not in (b"hdlr", b"keys", b"ilst"):
                    inner += 4
            if _scan(fh, inner, pos + size, depth + 1, budget):
                return True
        pos += size
    return False


# --- listing ----------------------------------------------------------------------------------

def _first(row: dict, cols) -> object:
    for c in cols:
        v = row.get(c)
        if v is not None and (not isinstance(v, str) or v.strip()):
            return v
    return None


def build_library(library: Path, recs: list[dict], folder_rows: list[dict]) -> Library:
    folders: list[Folder] = []
    by_pk: dict[int, Folder] = {}
    for row in folder_rows:
        uuid = _text(row.get("ZUUID"))
        if not uuid:
            continue
        name = _text(_first(row, ("ZENCRYPTEDNAME", "ZNAME"))) or "Untitled Folder"
        f = Folder(uuid, name, _num(row.get("ZRANK")) or 0.0)
        folders.append(f)
        if row.get("Z_PK") is not None:
            by_pk[_int(row["Z_PK"])] = f
    folders.sort(key=lambda f: (f.rank, f.name.casefold(), f.id))

    memos: list[Memo] = []
    for row in recs:
        uid = _text(row.get("ZUNIQUEID"))
        if not uid:
            continue
        if any(row.get(c) is not None for c in DELETED_COLUMNS):
            continue  # Recently Deleted
        local_d = _num(row.get("ZLOCALDURATION")) or 0.0
        dur = local_d if local_d > 0 else (_num(row.get("ZDURATION")) or 0.0)
        zpath = row.get("ZPATH")
        # Best effort "still being recorded": no audio path yet, or no duration yet.
        if not (isinstance(zpath, (str, bytes)) and str(zpath).strip()) or dur <= 0:
            continue
        recorded, unix = _when(_num(row.get("ZDATE")))
        title = _text(_first(row, TITLE_COLUMNS)) or fallback_title(unix)
        folder = by_pk.get(_int(row.get("ZFOLDER"))) if row.get("ZFOLDER") is not None else None
        audio = safe_audio_path(library, zpath)
        memos.append(Memo(
            id=uid, title=title, recorded=recorded, recorded_ts=unix,
            duration_s=round(dur, 3), folder_id=folder.id if folder else None,
            folder_name=folder.name if folder else None,
            favorite=bool(_int(row.get("ZSHAREDFLAGS")) & FAVORITE_BIT),
            local=audio is not None,
            apple_transcript=has_tsrp(audio) if audio is not None else False,
            format=audio_format(zpath), audio_path=audio))
    memos.sort(key=lambda m: (m.recorded_ts is not None, m.recorded_ts or 0.0, m.id), reverse=True)
    return Library(OK, f"{len(memos)} recordings", folders, memos)


def load_library(library: Path | str | None = None) -> Library:
    """Never raises for library problems; they become the status."""
    lib = Path(library).expanduser() if library else DEFAULT_LIBRARY.expanduser()
    try:
        check_library(lib)
        recs, folders = read_tables(lib)
        return build_library(lib, recs, folders)
    except LibraryError as exc:
        return Library(exc.status, exc.detail)


# --- import helpers ---------------------------------------------------------------------------

def sanitize_filename(title: str, limit: int = MAX_FILE_STEM) -> str:
    """A file-name stem: no path separators, control characters or ':', at most `limit` chars."""
    kept = "".join(" " if (ch in "/\\:" or unicodedata.category(ch).startswith("C")) else ch
                   for ch in title)
    stem = " ".join(kept.split()).lstrip(". ")[:limit].rstrip(". ")
    return stem or "Recording"


def output_stem(memo: Memo, title: str) -> str:
    when = datetime.fromtimestamp(memo.recorded_ts).strftime("%Y-%m-%d %H%M") \
        if memo.recorded_ts is not None else "undated"
    return f"{sanitize_filename(title)} ({when})"


def decodable(path: Path) -> bool:
    """True if PyAV can open the file and has a decoder for its first audio stream. `.qta`
    (QuickTime audio) demuxes as mov; for multi-track (layered) files only the first audio
    track is transcribed."""
    try:
        import av
        with av.open(str(path)) as c:
            if not c.streams.audio:
                return False
            stream = c.streams.audio[0]
            for i, packet in enumerate(c.demux(stream)):
                if packet.decode():
                    return True
                if i >= 64:
                    break
            return False
    except Exception:
        return False


# --- CLI ----------------------------------------------------------------------------------------

def _list_main(argv: list[str]) -> int:
    import argparse
    import json
    p = argparse.ArgumentParser(prog="liteecho voice-memos list",
                                description="List Voice Memos recordings (read-only).")
    p.add_argument("--json", action="store_true", help="print the contract v1 JSON object")
    p.add_argument("--library", default=None, help=f"library folder (default: {DEFAULT_LIBRARY})")
    args = p.parse_args(argv)
    try:
        lib = load_library(args.library)
    except Exception as exc:  # never crash the app's listing; no recording data in the detail
        lib = Library(UNREADABLE, f"Unexpected error while reading the library ({type(exc).__name__}).")
    if args.json:
        print(json.dumps(lib.to_json(), ensure_ascii=False))
    else:
        print(f"{lib.status}: {lib.detail}")
        for m in lib.memos:
            flag = "" if m.local else "  (not downloaded)"
            print(f"{m.id}  {m.recorded or '-'}  {m.duration_s:8.1f}s  {m.title}{flag}")
    return 0


_IMPORT_CODES = {NO_ACCESS: NO_ACCESS, NO_LIBRARY: "not-found", UNREADABLE: UNREADABLE}


def _import_main(argv: list[str]) -> int:
    from liteecho import cli
    from liteecho.events import EventSink

    sink = EventSink() if cli._events_requested(argv) else None
    p = cli.argparse.ArgumentParser(prog="liteecho voice-memos import",
                                    description="Transcribe one Voice Memos recording.")
    p.add_argument("id", help="the memo id (from `voice-memos list --json`)")
    p.add_argument("--library", default=None, help=f"library folder (default: {DEFAULT_LIBRARY})")
    cli.add_transcribe_options(
        p, output_help=f"output folder (default: {DEFAULT_OUTPUT}); file is "
                       "'<title> (<YYYY-MM-DD HHMM>).html'")
    args = cli.parse_with_sink(p, argv, sink)

    def fail(message: str, code: str) -> int:
        print(f"liteecho: error: {message}", file=sys.stderr)
        if sink:
            sink.error(message, code)
        return 1

    lib_path = Path(args.library).expanduser() if args.library else DEFAULT_LIBRARY.expanduser()
    lib = load_library(lib_path)
    if lib.status != OK:
        return fail(lib.detail, _IMPORT_CODES.get(lib.status, UNREADABLE))
    memo = next((m for m in lib.memos if m.id == args.id), None)
    if memo is None:
        return fail("No Voice Memos recording has that id (it may have been deleted).", "not-found")
    if not memo.local or memo.audio_path is None:
        return fail("This recording isn't downloaded to this Mac. Open it in Voice Memos first.",
                    "not-local")

    title = args.title if args.title is not None else memo.title
    out_dir = Path(args.output_folder).expanduser() if args.output_folder else DEFAULT_OUTPUT.expanduser()
    extra = [("liteecho:source", "voice-memos"), ("liteecho:source-id", memo.id)]
    if memo.recorded:
        extra.append(("liteecho:recorded", memo.recorded))
    if memo.folder_name:
        extra.append(("liteecho:source-folder", memo.folder_name))

    audio = memo.audio_path

    def prepare(tmp_dir: Path) -> Path:
        # Copy, never move or open for writing; the copy is what gets decoded.
        copy = tmp_dir / ("memo" + (audio.suffix.lower() or ".m4a"))
        shutil.copyfile(audio, copy)
        if not decodable(copy):
            raise cli.JobError(f"This recording's audio ({memo.format or 'unknown'} format) can't "
                               "be decoded.", "unsupported-format")
        return copy

    job = cli.Job(input=None, audio_path=str(audio), title=title, out_dir=out_dir,
                  out_stem=output_stem(memo, title), unique=True, extra_meta=extra,
                  prepare=prepare)
    return cli.execute(args, p, sink, job)


def main(argv: list[str]) -> int:
    if argv and argv[0] == "list":
        return _list_main(argv[1:])
    if argv and argv[0] == "import":
        return _import_main(argv[1:])
    print("usage: liteecho voice-memos {list,import} ...\n"
          "  list --json [--library DIR]\n"
          "  import ID [--library DIR] [--output-folder DIR] [transcribe options] [--events jsonl]",
          file=sys.stderr)
    return 2

