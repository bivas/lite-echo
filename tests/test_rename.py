import json
import os

import pytest

from liteecho.models import DiarSeg, RenderOptions, Segment, Word
from liteecho.normalize import parse
from liteecho.rename import MAX_NAME, RenameError, clean_name, main, rename_text
from liteecho.render import render_html


def transcript() -> str:
    segs = [Segment(0, 1, " hi", [Word(" hi", 0, 1)]), Segment(1, 2, " yo", [Word(" yo", 1, 2)]),
            Segment(2, 3, " ok", [Word(" ok", 2, 3)])]
    diar = [DiarSeg(0, 1000, "A"), DiarSeg(1000, 2000, "B"), DiarSeg(2000, 3000, "A")]
    return render_html(segs, diar, [], RenderOptions(title="t", audio_path="/a/t.m4a", language="en",
                                                     created="2026-01-01T00:00:00Z"))


def names(text, sid):
    root = parse(text)
    return [el.text for el in root.iter("span")
            if el.get("class") == "speaker" and el.get("data-speaker") == sid]


@pytest.fixture
def html_file(tmp_path):
    f = tmp_path / "t.html"
    f.write_text(transcript(), encoding="utf-8")
    return f


def test_rename_by_id_everywhere(html_file):
    assert main([str(html_file), "--map", "S1=Dana", "--map", "S2=Avi"]) == 0
    text = html_file.read_text(encoding="utf-8")
    assert names(text, "S1") == ["Dana"] * 3  # header list + two turns
    assert names(text, "S2") == ["Avi"] * 2
    # IDs untouched, so a second rename still uses them
    assert main([str(html_file), "--map", "S1=Dana Cohen"]) == 0
    assert names(html_file.read_text(encoding="utf-8"), "S1") == ["Dana Cohen"] * 3


def test_only_speaker_text_changes(html_file):
    before = html_file.read_text(encoding="utf-8")
    main([str(html_file), "--map", "S2=Avi"])
    after = html_file.read_text(encoding="utf-8")
    assert before.replace('data-speaker="S2">S2<', 'data-speaker="S2">Avi<') == after


@pytest.mark.parametrize("hostile", ['<img src=x onerror=alert(1)>', '"><script>alert(1)</script>',
                                     "a&amp;b", "x\u0000\u0007‮\ny"])
def test_hostile_names_come_out_inert(html_file, hostile):
    assert main([str(html_file), "--map", f"S1={hostile}"]) == 0
    text = html_file.read_text(encoding="utf-8")
    root = parse(text)  # still well-formed
    assert not list(root.iter("script")) and not list(root.iter("img"))
    shown = names(text, "S1")
    assert len(shown) == 3 and len(set(shown)) == 1
    assert not set(shown[0]) & set('<>"&') and shown[0] == clean_name(hostile)
    assert "<script" not in text and "<img" not in text


def test_clean_name():
    assert clean_name("  Dana   Cohen \t") == "Dana Cohen"
    assert clean_name('<b>"A&B"</b>') == "bAB/b"
    assert len(clean_name("x" * 100)) == MAX_NAME
    assert clean_name("O'Brien") == "O'Brien"


def test_apostrophe_is_escaped_on_write(html_file):
    main([str(html_file), "--map", "S1=O'Brien"])
    text = html_file.read_text(encoding="utf-8")
    assert "O&#x27;Brien" in text and names(text, "S1")[0] == "O'Brien"


def test_rejects_non_liteecho_file(tmp_path, capsys):
    f = tmp_path / "other.html"
    f.write_text('<html><body><span class="speaker" data-speaker="S1">S1</span></body></html>')
    before = f.read_text()
    assert main([str(f), "--map", "S1=Dana"]) == 1
    assert "not a LiteEcho transcript" in capsys.readouterr().err
    assert f.read_text() == before


def test_rejects_binary_file(tmp_path):
    f = tmp_path / "x.html"
    f.write_bytes(b"\xff\xfe\x00")
    assert main([str(f), "--map", "S1=Dana"]) == 1


@pytest.mark.parametrize("bad", ["S00=Dana", "Dana", "S1", "s1=x", "S1=<>", "S1=   "])
def test_bad_maps_fail_without_touching_file(html_file, bad):
    before = html_file.read_text(encoding="utf-8")
    assert main([str(html_file), "--map", bad]) == 1
    assert html_file.read_text(encoding="utf-8") == before


def test_unknown_id_fails(html_file, capsys):
    assert main([str(html_file), "--map", "S9=Dana"]) == 1
    assert "S9" in capsys.readouterr().err


def test_missing_file(tmp_path):
    assert main([str(tmp_path / "nope.html"), "--map", "S1=Dana"]) == 1


def test_atomic_replace_leaves_no_temp_and_keeps_mode(html_file):
    os.chmod(html_file, 0o640)
    main([str(html_file), "--map", "S1=Dana"])
    assert sorted(p.name for p in html_file.parent.iterdir()) == ["t.html"]
    assert html_file.stat().st_mode & 0o777 == 0o640


def test_events_jsonl(html_file, capsys):
    assert main([str(html_file), "--map", "S1=Dana", "--events", "jsonl"]) == 0
    ev = [json.loads(x) for x in capsys.readouterr().out.splitlines()]
    assert ev == [{"type": "done", "output": str(html_file.resolve())}]
    assert main([str(html_file), "--map", "S7=X", "--events", "jsonl"]) == 1
    ev = [json.loads(x) for x in capsys.readouterr().out.splitlines()]
    assert ev[-1]["type"] == "error" and "S7" in ev[-1]["message"]


def test_rename_text_requires_format_meta():
    with pytest.raises(RenameError):
        rename_text("<html></html>", {"S1": "x"})


def test_cli_dispatch(html_file):
    from liteecho.cli import main as cli_main
    assert cli_main(["rename-speakers", str(html_file), "--map", "S2=Avi"]) == 0
    assert names(html_file.read_text(encoding="utf-8"), "S2") == ["Avi", "Avi"]
