"""Voice Memos reader and CLI (docs/transcript-format.md, "Voice Memos (contract v1)").

Everything runs against a synthetic library in a tmp dir; the real (TCC-protected) library is
never touched.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import sqlite3
import struct
import subprocess
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

import pytest

from liteecho import voicememos as vm

EPOCH = vm.CORE_DATA_EPOCH
FFMPEG = shutil.which("ffmpeg")
needs_ffmpeg = pytest.mark.skipif(FFMPEG is None, reason="ffmpeg not available")


def core(iso: str) -> float:
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp() - EPOCH


def _sine(path: Path, fmt: str = "ipod", codec: str = "aac") -> None:
    subprocess.run([FFMPEG, "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                    "sine=frequency=440:duration=0.5", "-c:a", codec, "-f", fmt, str(path)],
                   check=True)


@pytest.fixture(scope="session")
def audio_src(tmp_path_factory):
    if FFMPEG is None:
        return None
    d = tmp_path_factory.mktemp("audio")
    _sine(d / "sine.m4a")
    _sine(d / "sine.qta", fmt="mov")
    return d


FULL_SCHEMA = """
CREATE TABLE ZFOLDER (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZRANK INTEGER,
    ZENCRYPTEDNAME VARCHAR, ZUUID VARCHAR);
CREATE TABLE ZCLOUDRECORDING (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
    ZFLAGS INTEGER, ZSHAREDFLAGS INTEGER, ZFOLDER INTEGER, ZDATE TIMESTAMP, ZDURATION FLOAT,
    ZLOCALDURATION FLOAT, ZEVICTIONDATE TIMESTAMP, ZCUSTOMLABEL VARCHAR,
    ZCUSTOMLABELFORSORTING VARCHAR, ZENCRYPTEDTITLE VARCHAR, ZPATH VARCHAR, ZUNIQUEID VARCHAR,
    "ZX; DROP TABLE ZFOLDER" VARCHAR);
"""

# Drift: no ZENCRYPTEDTITLE / ZLOCALDURATION / ZSHAREDFLAGS, ZTRASHEDDATE instead of
# ZEVICTIONDATE, ZNAME instead of ZENCRYPTEDNAME.
DRIFT_SCHEMA = """
CREATE TABLE ZFOLDER (Z_PK INTEGER PRIMARY KEY, ZRANK INTEGER, ZNAME VARCHAR, ZUUID VARCHAR);
CREATE TABLE ZCLOUDRECORDING (Z_PK INTEGER PRIMARY KEY, ZFLAGS INTEGER, ZFOLDER INTEGER,
    ZDATE TIMESTAMP, ZDURATION FLOAT, ZTRASHEDDATE TIMESTAMP, ZCUSTOMLABEL VARCHAR,
    ZPATH VARCHAR, ZUNIQUEID VARCHAR);
"""


class Lib:
    def __init__(self, root: Path, conn: sqlite3.Connection):
        self.root = root
        self.conn = conn  # held open, like Voice Memos itself: the WAL stays un-checkpointed

    def snapshot(self) -> dict:
        out = {}
        for p in sorted(self.root.rglob("*")):
            if p.is_symlink() or not p.is_file():
                continue
            st = p.stat()
            out[str(p.relative_to(self.root))] = (st.st_size, st.st_mtime_ns,
                                                  hashlib.sha256(p.read_bytes()).hexdigest())
        return out


def _make_db(db: Path, schema: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db, isolation_level=None)
    assert conn.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
    conn.executescript(schema)
    return conn


def _insert(conn, table, **cols):
    names = ", ".join(f'"{k}"' for k in cols)
    marks = ", ".join("?" for _ in cols)
    conn.execute(f"INSERT INTO {table} ({names}) VALUES ({marks})", list(cols.values()))


@pytest.fixture
def library(tmp_path, audio_src):
    if audio_src is None:
        pytest.skip("ffmpeg not available")
    root = tmp_path / "Recordings"
    root.mkdir()
    outside = tmp_path / "outside.m4a"
    shutil.copyfile(audio_src / "sine.m4a", outside)
    shutil.copyfile(audio_src / "sine.m4a", root / "20261126 084200-AAAA.m4a")
    shutil.copyfile(audio_src / "sine.m4a", root / "20260101 090000-BBBB.m4a")
    shutil.copyfile(audio_src / "sine.m4a", root / "deleted.m4a")
    shutil.copyfile(audio_src / "sine.qta", root / "layered.qta")
    shutil.copyfile(audio_src / "sine.m4a", root / "wal.m4a")
    (root / "empty.m4a").write_bytes(b"")
    (root / "junk.m4a").write_bytes(b"not audio at all" * 10)
    os.symlink(outside, root / "link.m4a")

    conn = _make_db(root / vm.DB_NAME, FULL_SCHEMA)
    _insert(conn, "ZFOLDER", Z_PK=1, ZRANK=2, ZENCRYPTEDNAME="Work", ZUUID="F-WORK")
    _insert(conn, "ZFOLDER", Z_PK=2, ZRANK=1, ZENCRYPTEDNAME="Ideas", ZUUID="F-IDEAS")
    R = "ZCLOUDRECORDING"
    _insert(conn, R, ZUNIQUEID="A", ZENCRYPTEDTITLE="Customer call", ZCUSTOMLABEL="2026-11-26",
            ZDATE=core("2026-11-26T08:42:00Z"), ZDURATION=1311.4, ZLOCALDURATION=0.0,
            ZPATH="20261126 084200-AAAA.m4a", ZFOLDER=1, ZSHAREDFLAGS=0x02, ZFLAGS=0x04,
            **{"ZX; DROP TABLE ZFOLDER": "x"})
    _insert(conn, R, ZUNIQUEID="B", ZDATE=core("2026-01-01T09:00:00Z"), ZDURATION=10.0,
            ZLOCALDURATION=9.5, ZPATH="20260101 090000-BBBB.m4a")  # no title at all
    _insert(conn, R, ZUNIQUEID="DEL", ZENCRYPTEDTITLE="Deleted", ZDATE=core("2026-11-20T10:00:00Z"),
            ZDURATION=5.0, ZPATH="deleted.m4a", ZEVICTIONDATE=core("2026-11-21T10:00:00Z"))
    _insert(conn, R, ZUNIQUEID="TRAV", ZENCRYPTEDTITLE="Traversal", ZDATE=core("2026-11-19T10:00:00Z"),
            ZDURATION=5.0, ZPATH="../../etc/passwd")
    _insert(conn, R, ZUNIQUEID="ABS", ZENCRYPTEDTITLE="Absolute", ZDATE=core("2026-11-18T10:00:00Z"),
            ZDURATION=5.0, ZPATH=str(root / "20261126 084200-AAAA.m4a"))
    _insert(conn, R, ZUNIQUEID="CLOUD", ZCUSTOMLABELFORSORTING="From iPhone",
            ZDATE=core("2026-11-17T10:00:00Z"), ZDURATION=7.0, ZPATH="not-downloaded.m4a",
            ZFOLDER=2)
    _insert(conn, R, ZUNIQUEID="LINK", ZENCRYPTEDTITLE="Symlink", ZDATE=core("2026-11-16T10:00:00Z"),
            ZDURATION=5.0, ZPATH="link.m4a")
    _insert(conn, R, ZUNIQUEID="EMPTY", ZENCRYPTEDTITLE="Empty", ZDATE=core("2026-11-15T10:00:00Z"),
            ZDURATION=5.0, ZPATH="empty.m4a")
    _insert(conn, R, ZUNIQUEID="REC0", ZENCRYPTEDTITLE="Recording now", ZDATE=core("2026-11-26T09:00:00Z"),
            ZDURATION=0.0, ZPATH="in-progress.m4a")
    _insert(conn, R, ZUNIQUEID="NOPATH", ZENCRYPTEDTITLE="No path", ZDATE=core("2026-11-26T09:01:00Z"),
            ZDURATION=3.0)
    _insert(conn, R, ZUNIQUEID="QTA", ZENCRYPTEDTITLE='<script>alert("x")</script> & co: plan/b',
            ZDATE=core("2026-06-01T12:34:00Z"), ZDURATION=0.5, ZPATH="layered.qta", ZFOLDER=1)
    _insert(conn, R, ZUNIQUEID="JUNK", ZENCRYPTEDTITLE="Junk", ZDATE=core("2026-05-01T12:00:00Z"),
            ZDURATION=1.0, ZPATH="junk.m4a")
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")  # everything so far is in the main file
    conn.execute("PRAGMA wal_autocheckpoint=0")
    # Newest memo exists only in the WAL.
    _insert(conn, R, ZUNIQUEID="WAL", ZENCRYPTEDTITLE="Only in WAL", ZDATE=core("2026-11-26T10:00:00Z"),
            ZDURATION=0.5, ZPATH="wal.m4a")
    lib = Lib(root, conn)
    yield lib
    conn.close()


@pytest.fixture
def scratch(tmp_path, monkeypatch):
    import tempfile
    d = tmp_path / "scratch"
    d.mkdir()
    monkeypatch.setattr(tempfile, "tempdir", str(d))
    return d


@pytest.fixture
def utc(monkeypatch):
    monkeypatch.setenv("TZ", "UTC")
    time.tzset()
    yield
    monkeypatch.undo()
    time.tzset()


def _list(capsys, *argv) -> dict:
    from liteecho.cli import main
    assert main(["voice-memos", "list", "--json", *argv]) == 0
    return json.loads(capsys.readouterr().out)


# --- listing ------------------------------------------------------------------------------------

def test_list_json_shape_order_and_filtering(library, capsys, scratch, utc):
    before = library.snapshot()
    out = _list(capsys, "--library", str(library.root))
    assert library.snapshot() == before  # nothing in the library changed
    assert list(scratch.iterdir()) == []  # the private DB copy was removed
    assert set(out) == {"status", "detail", "folders", "memos"}
    assert out["status"] == "ok"
    assert out["folders"] == [{"id": "F-IDEAS", "name": "Ideas"}, {"id": "F-WORK", "name": "Work"}]
    ids = [m["id"] for m in out["memos"]]
    # newest first; DEL (deleted), REC0 (zero duration) and NOPATH (no path) excluded
    assert ids == ["WAL", "A", "TRAV", "ABS", "CLOUD", "LINK", "EMPTY", "QTA", "JUNK", "B"]
    for m in out["memos"]:
        assert set(m) == {"id", "title", "recorded", "duration_s", "folder_id", "favorite",
                          "local", "apple_transcript", "format"}
        assert m["title"]
    a = out["memos"][1]
    assert a == {"id": "A", "title": "Customer call", "recorded": "2026-11-26T08:42:00Z",
                 "duration_s": 1311.4, "folder_id": "F-WORK", "favorite": True, "local": True,
                 "apple_transcript": False, "format": "m4a"}
    by = {m["id"]: m for m in out["memos"]}
    assert by["B"]["title"] == "Recording 2026-01-01 09:00" and by["B"]["duration_s"] == 9.5
    assert by["B"]["folder_id"] is None and by["B"]["favorite"] is False
    assert by["CLOUD"]["title"] == "From iPhone" and by["CLOUD"]["local"] is False
    assert by["CLOUD"]["folder_id"] == "F-IDEAS"
    assert by["QTA"]["format"] == "qta" and by["QTA"]["local"] is True
    for unsafe in ("TRAV", "ABS", "LINK", "EMPTY"):
        assert by[unsafe]["local"] is False, unsafe


def test_wal_only_row_is_read_from_the_copy(library):
    # Proof that the row really lives only in the WAL: the main file alone doesn't have it.
    alone = library.root.parent / "alone"
    alone.mkdir()
    shutil.copyfile(library.root / vm.DB_NAME, alone / vm.DB_NAME)
    c = sqlite3.connect(f"file:{alone / vm.DB_NAME}?mode=ro", uri=True)
    assert c.execute("SELECT COUNT(*) FROM ZCLOUDRECORDING WHERE ZUNIQUEID='WAL'").fetchone()[0] == 0
    c.close()
    assert (library.root / (vm.DB_NAME + "-wal")).stat().st_size > 0
    ids = [m.id for m in vm.load_library(library.root).memos]
    assert "WAL" in ids


def test_only_a_read_only_copy_is_opened(library, monkeypatch):
    seen = []
    real = sqlite3.connect

    def spy(target, *a, **kw):
        seen.append(str(target))
        return real(target, *a, **kw)

    monkeypatch.setattr(vm.sqlite3, "connect", spy)
    assert vm.load_library(library.root).status == "ok"
    assert seen and all(s.startswith("file:") and s.endswith("?mode=ro") for s in seen)
    assert not any(str(library.root) in s or "Recordings/" in s for s in seen)
    assert all("immutable" not in s for s in seen)


def test_schema_drift_missing_and_renamed_columns(tmp_path, audio_src, capsys, utc):
    if audio_src is None:
        pytest.skip("ffmpeg not available")
    root = tmp_path / "Recordings"
    root.mkdir()
    shutil.copyfile(audio_src / "sine.m4a", root / "a.m4a")
    conn = _make_db(root / vm.DB_NAME, DRIFT_SCHEMA)
    _insert(conn, "ZFOLDER", Z_PK=7, ZRANK=0, ZNAME="Old style", ZUUID="F-OLD")
    _insert(conn, "ZCLOUDRECORDING", ZUNIQUEID="X", ZCUSTOMLABEL="Old label", ZFOLDER=7,
            ZDATE=core("2025-03-04T05:06:07Z"), ZDURATION=12.25, ZPATH="a.m4a", ZFLAGS=0x08)
    _insert(conn, "ZCLOUDRECORDING", ZUNIQUEID="T", ZCUSTOMLABEL="Trashed",
            ZDATE=core("2025-03-05T05:06:07Z"), ZDURATION=3.0, ZPATH="a.m4a",
            ZTRASHEDDATE=core("2025-03-06T00:00:00Z"))
    conn.close()
    out = _list(capsys, "--library", str(root))
    assert out["status"] == "ok"
    assert out["folders"] == [{"id": "F-OLD", "name": "Old style"}]
    assert out["memos"] == [{"id": "X", "title": "Old label", "recorded": "2025-03-04T05:06:07Z",
                             "duration_s": 12.25, "folder_id": "F-OLD", "favorite": False,
                             "local": True, "apple_transcript": False, "format": "m4a"}]


def test_no_folder_table_and_no_recording_id(tmp_path):
    root = tmp_path / "Recordings"
    root.mkdir()
    conn = _make_db(root / vm.DB_NAME, "CREATE TABLE ZCLOUDRECORDING (Z_PK INTEGER PRIMARY KEY, ZDATE FLOAT);")
    conn.execute("INSERT INTO ZCLOUDRECORDING (ZDATE) VALUES (1.0)")
    conn.close()
    lib = vm.load_library(root)
    assert lib.status == "unreadable" and lib.memos == []


def test_missing_library_is_no_library(tmp_path, capsys):
    out = _list(capsys, "--library", str(tmp_path / "nope"))
    assert out == {"status": "no-library", "detail": out["detail"], "folders": [], "memos": []}
    assert out["detail"]


def test_library_without_database_is_no_library(tmp_path):
    assert vm.load_library(tmp_path).status == "no-library"


@pytest.mark.skipif(hasattr(os, "geteuid") and os.geteuid() == 0, reason="root ignores modes")
def test_unlistable_library_is_no_access(tmp_path, capsys):
    root = tmp_path / "Recordings"
    root.mkdir()
    (root / vm.DB_NAME).write_bytes(b"x")
    root.chmod(0)
    try:
        out = _list(capsys, "--library", str(root))
    finally:
        root.chmod(0o755)
    assert out["status"] == "no-access" and out["memos"] == [] and out["folders"] == []


@pytest.mark.skipif(hasattr(os, "geteuid") and os.geteuid() == 0, reason="root ignores modes")
def test_unreadable_database_is_no_access(library, capsys):
    db = library.root / vm.DB_NAME
    db.chmod(0)
    try:
        out = _list(capsys, "--library", str(library.root))
    finally:
        db.chmod(0o644)
    assert out["status"] == "no-access"


def test_eperm_from_tcc_is_no_access(tmp_path, monkeypatch):
    # TCC: stat works, listing fails with EPERM.
    def deny(path):
        raise PermissionError(1, "Operation not permitted")
    monkeypatch.setattr(vm.os, "listdir", deny)
    tmp_path.joinpath(vm.DB_NAME).write_bytes(b"")
    assert vm.load_library(tmp_path).status == "no-access"


def test_corrupt_database_is_unreadable(tmp_path, capsys, scratch):
    (tmp_path / vm.DB_NAME).write_bytes(b"this is not sqlite" * 100)
    out = _list(capsys, "--library", str(tmp_path))
    assert out["status"] == "unreadable" and out["memos"] == []
    assert list(scratch.iterdir()) == []


def test_torn_copy_is_retried_once(library, monkeypatch):
    real = vm._copy_db
    calls = []

    def flaky(lib, dest):
        calls.append(dest)
        copy = real(lib, dest)
        if len(calls) == 1:
            copy.write_bytes(b"torn" * 2000)  # damage the copy (only ever the copy)
        return copy

    monkeypatch.setattr(vm, "_copy_db", flaky)
    lib = vm.load_library(library.root)
    assert len(calls) == 2 and calls[0] != calls[1]
    assert lib.status == "ok" and "WAL" in [m.id for m in lib.memos]
    assert not any(c.exists() for c in calls)


def test_failed_quick_check_is_retried_then_unreadable(library, monkeypatch):
    results = iter([False, True])
    monkeypatch.setattr(vm, "_quick_check_ok", lambda conn: next(results))
    assert vm.load_library(library.root).status == "ok"
    monkeypatch.setattr(vm, "_quick_check_ok", lambda conn: False)
    lib = vm.load_library(library.root)
    assert lib.status == "unreadable" and "integrity" in lib.detail


# --- unit helpers -------------------------------------------------------------------------------

def test_safe_audio_path_rejections(tmp_path):
    root = tmp_path / "lib"
    (root / "sub").mkdir(parents=True)
    (root / "sub" / "ok.m4a").write_bytes(b"1")
    (tmp_path / "secret.m4a").write_bytes(b"1")
    assert vm.safe_audio_path(root, "sub/ok.m4a") == (root / "sub" / "ok.m4a").resolve()
    for bad in ("../secret.m4a", "sub/../../secret.m4a", str(tmp_path / "secret.m4a"),
                "/etc/passwd", "", "  ", None, 5, "sub", "a\x00b", "~/secret.m4a", "sub/../sub/ok.m4a"):
        assert vm.safe_audio_path(root, bad) is None, bad
    os.symlink(root / "sub", root / "alias")
    assert vm.safe_audio_path(root, "alias/ok.m4a") is not None  # stays inside


def _box(kind: bytes, payload: bytes = b"") -> bytes:
    return struct.pack(">I4s", 8 + len(payload), kind) + payload


def test_tsrp_probe(tmp_path):
    ftyp = _box(b"ftyp", b"M4A \x00\x00\x00\x00")
    mdat = _box(b"mdat", b"\x00" * 5000)
    m4a = ftyp + mdat + _box(b"moov", _box(b"mvhd", b"\x00" * 100) + _box(b"trak", _box(b"udta", _box(b"tsrp", b'{"locale":"en"}'))))
    qta = ftyp + _box(b"moov", _box(b"meta", _box(b"hdlr", b"\x00" * 24) + _box(b"keys", b"\x00" * 8 + b"mdtacom.apple.VoiceMemos.tsrp")))
    none = ftyp + mdat + _box(b"moov", _box(b"trak", _box(b"udta", _box(b"name", b"x"))))
    big = ftyp + struct.pack(">I4sQ", 1, b"mdat", 16 + 10) + b"\x00" * 10 + _box(b"moov", _box(b"trak", _box(b"udta", _box(b"tsrp"))))
    broken = ftyp + struct.pack(">I4s", 999999, b"moov")
    for name, data, want in [("a", m4a, True), ("b", qta, True), ("c", none, False),
                             ("d", big, True), ("e", broken, False)]:
        p = tmp_path / name
        p.write_bytes(data)
        assert vm.has_tsrp(p) is want, name


def test_list_reports_apple_transcript_from_file(library, capsys):
    p = library.root / "20260101 090000-BBBB.m4a"
    with open(p, "ab") as fh:  # an extra top-level moov-like box carrying tsrp
        fh.write(_box(b"moov", _box(b"trak", _box(b"udta", _box(b"tsrp", b"{}")))))
    out = _list(capsys, "--library", str(library.root))
    by = {m["id"]: m for m in out["memos"]}
    assert by["B"]["apple_transcript"] is True and by["A"]["apple_transcript"] is False


@pytest.mark.parametrize("title,stem", [
    ("Customer call", "Customer call"),
    ("a/b\\c:d", "a b c d"),
    ("tab\there\nnew\x07bell", "tab here new bell"),
    ("../../evil", "evil"),
    ("   ", "Recording"),
    ("x" * 300, "x" * 120),
])
def test_sanitize_filename(title, stem):
    assert vm.sanitize_filename(title) == stem


@needs_ffmpeg
def test_qta_decodes(audio_src, tmp_path):
    from liteecho.audio import convert_to_wav
    assert vm.decodable(audio_src / "sine.qta")
    wav, _ = convert_to_wav(str(audio_src / "sine.qta"), str(tmp_path / "o.wav"))
    import soundfile as sf
    assert sf.info(wav).duration > 0.3


# --- import -------------------------------------------------------------------------------------

def _import_setup(monkeypatch, tmp_path, library):
    from test_events import _fake_pipeline
    import liteecho.audio as audio_mod
    _fake_pipeline(monkeypatch, tmp_path)
    seen = {}

    def convert(path, output_path=None, on_progress=None):
        seen["path"] = Path(path)
        seen["bytes"] = Path(path).read_bytes()
        on_progress(0.0, 10.0)
        on_progress(10.0, 10.0)
        return output_path, 0

    monkeypatch.setattr(audio_mod, "convert_to_wav", convert)
    return seen


def _events(capsys):
    return [json.loads(x) for x in capsys.readouterr().out.splitlines()]


def _meta(html: str) -> dict:
    root = ET.fromstring(html.split("\n", 1)[1])
    return {m.get("name"): m.get("content") for m in root.iter("meta") if m.get("name")}


def test_import_end_to_end(library, tmp_path, monkeypatch, capsys, scratch, utc):
    from liteecho.cli import main
    seen = _import_setup(monkeypatch, tmp_path, library)
    out_dir = tmp_path / "out"
    before = library.snapshot()
    argv = ["voice-memos", "import", "A", "--library", str(library.root),
            "--output-folder", str(out_dir), "--events", "jsonl", "--speakers", "2"]
    assert main(argv) == 0
    ev = _events(capsys)
    assert ev[-1]["type"] == "done"
    expected = out_dir / "Customer call (2026-11-26 0842).html"
    assert ev[-1]["output"] == str(expected) and expected.is_file()
    # decoded a copy, outside the library, with identical bytes
    src = (library.root / "20261126 084200-AAAA.m4a").resolve()
    assert not seen["path"].resolve().is_relative_to(library.root.resolve())
    assert seen["bytes"] == src.read_bytes()
    assert library.snapshot() == before
    assert list(scratch.iterdir()) == []
    html = expected.read_text(encoding="utf-8")
    meta = _meta(html)
    assert meta["liteecho:source"] == "voice-memos"
    assert meta["liteecho:source-id"] == "A"
    assert meta["liteecho:recorded"] == "2026-11-26T08:42:00Z"
    assert meta["liteecho:source-folder"] == "Work"
    assert meta["liteecho:audio"] == str(src)
    assert meta["liteecho:speakers-mode"] == "exact:2"
    assert "<h1>Customer call</h1>" in html and "<title>Customer call</title>" in html

    # second import: never overwrite
    assert main(argv) == 0
    assert _events(capsys)[-1]["output"] == str(out_dir / "Customer call (2026-11-26 0842) 2.html")
    assert main(argv) == 0
    assert _events(capsys)[-1]["output"] == str(out_dir / "Customer call (2026-11-26 0842) 3.html")
    assert library.snapshot() == before


def test_import_qta_title_escaping_and_override(library, tmp_path, monkeypatch, capsys, utc):
    from liteecho.cli import main
    _import_setup(monkeypatch, tmp_path, library)
    out_dir = tmp_path / "out"
    assert main(["voice-memos", "import", "QTA", "--library", str(library.root),
                 "--output-folder", str(out_dir), "--events", "jsonl"]) == 0
    out = Path(_events(capsys)[-1]["output"])
    assert out.parent == out_dir
    assert out.name == '<script>alert("x")< script> & co plan b (2026-06-01 1234).html'
    html = out.read_text(encoding="utf-8")
    assert "<script" not in html
    assert "<h1>&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; co: plan/b</h1>" in html
    assert "liteecho:source-folder" in html
    _meta(html)  # still well-formed

    assert main(["voice-memos", "import", "B", "--library", str(library.root),
                 "--output-folder", str(out_dir), "--title", "My <b> title", "--events", "jsonl"]) == 0
    out = Path(_events(capsys)[-1]["output"])
    assert out.name == "My <b> title (2026-01-01 0900).html"
    html = out.read_text(encoding="utf-8")
    assert "<h1>My &lt;b&gt; title</h1>" in html
    assert "liteecho:source-folder" not in html  # unfiled


@pytest.mark.parametrize("memo_id,code", [("NOPE", "not-found"), ("DEL", "not-found"),
                                          ("CLOUD", "not-local"), ("TRAV", "not-local"),
                                          ("ABS", "not-local"), ("LINK", "not-local"),
                                          ("JUNK", "unsupported-format")])
def test_import_errors(library, tmp_path, monkeypatch, capsys, memo_id, code):
    from liteecho.cli import main
    _import_setup(monkeypatch, tmp_path, library)
    out_dir = tmp_path / "out"
    assert main(["voice-memos", "import", memo_id, "--library", str(library.root),
                 "--output-folder", str(out_dir), "--events", "jsonl"]) != 0
    ev = _events(capsys)
    assert ev[-1]["type"] == "error" and ev[-1]["detail"] == code
    assert not any(e["type"] == "done" for e in ev)
    assert not out_dir.exists() or list(out_dir.iterdir()) == []


def test_import_no_access_and_no_library(tmp_path, monkeypatch, capsys):
    from liteecho.cli import main
    assert main(["voice-memos", "import", "A", "--library", str(tmp_path / "missing"),
                 "--output-folder", str(tmp_path / "o"), "--events", "jsonl"]) == 1
    assert _events(capsys)[-1]["detail"] == "not-found"
    monkeypatch.setattr(vm.os, "listdir", lambda p: (_ for _ in ()).throw(PermissionError(1, "nope")))
    assert main(["voice-memos", "import", "A", "--library", str(tmp_path),
                 "--output-folder", str(tmp_path / "o"), "--events", "jsonl"]) == 1
    assert _events(capsys)[-1]["detail"] == "no-access"
    # without --events: message on stderr, non-zero exit, nothing on stdout
    assert main(["voice-memos", "import", "A", "--library", str(tmp_path)]) == 1
    cap = capsys.readouterr()
    assert cap.out == "" and "Full Disk Access" in cap.err


def test_import_bad_option_is_error_event(capsys):
    from liteecho.cli import main
    with pytest.raises(SystemExit):
        main(["voice-memos", "import", "A", "--speakers", "2", "--min-speakers", "1",
              "--events", "jsonl"])
    assert _events(capsys)[-1]["type"] == "error"


def test_title_flag_on_main_command(tmp_path, monkeypatch, capsys):
    from test_events import _fake_pipeline
    from liteecho.cli import main
    audio = _fake_pipeline(monkeypatch, tmp_path)
    assert main([str(audio), "--title", "Board <meeting> & \"notes\"", "--output-folder",
                 str(tmp_path / "o"), "--events", "jsonl"]) == 0
    out = tmp_path / "o" / "talk.html"  # file name is still the stem
    html = out.read_text(encoding="utf-8")
    assert "<title>Board &lt;meeting&gt; &amp; &quot;notes&quot;</title>" in html
    assert "<h1>Board &lt;meeting&gt; &amp; &quot;notes&quot;</h1>" in html
    assert "liteecho:source" not in html
    capsys.readouterr()
    assert main([str(audio), "--output-folder", str(tmp_path / "o2")]) == 0
    assert "<h1>talk</h1>" in (tmp_path / "o2" / "talk.html").read_text(encoding="utf-8")
