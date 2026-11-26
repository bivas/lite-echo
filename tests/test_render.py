import re
import xml.etree.ElementTree as ET

import pytest

from liteecho.models import DiarSeg, RenderOptions, Segment, Word
from liteecho.normalize import parse
from liteecho.render import (CSP, build_turns, clock, pause_label, render_html,
                             sampled_windows)


def seg(start, end, *words, temperature=0.0):
    """Segment from (text, start, end) word tuples."""
    ws = [Word(t, a, b) for t, a, b in words]
    return Segment(start, end, "".join(w.word for w in ws), ws, temperature)


def opts(**kw):
    base = dict(title="talk", audio_path="/a/talk.m4a", language="en", language_mode="fixed",
                speakers_mode="auto", duration_ms=20000, created="2026-01-02T03:04:05Z",
                app_version="0.3.0")
    base.update(kw)
    return RenderOptions(**base)


def chunks(*spans_s):
    return [{"start": int(a * 16000), "end": int(b * 16000)} for a, b in spans_s]


SEGS = [
    seg(0.0, 2.0, (" Hello", 0.0, 0.5), (" there.", 0.6, 1.2), (" How", 1.3, 1.6), (" are", 1.6, 2.0)),
    seg(2.0, 6.0, (" you?", 2.0, 2.4), (" Fine,", 4.0, 4.5), (" thanks.", 4.6, 5.2)),
    seg(9.0, 10.0, (" Good.", 9.0, 9.6)),
]
DIAR = [DiarSeg(0, 2500, "SPEAKER_07"), DiarSeg(3800, 5400, "SPEAKER_02"), DiarSeg(8800, 10000, "SPEAKER_07")]


def test_turns_speakers_and_pauses():
    turns = build_turns(SEGS, DIAR, chunks((0, 2.4), (4.0, 5.2), (9.0, 9.6)), 20000)
    assert [t.speaker for t in turns] == ["S1", "S2", "S1"]
    assert turns[0].items[0] == "Hello there. How are you?"
    assert turns[0].items[1].ms == 1600  # VAD silence 2.4-4.0 s, ends turn 1
    assert turns[1].items[0] == "Fine, thanks."
    assert turns[1].items[1].ms == 3800  # 5.2-9.0 s
    assert (turns[2].start_ms, turns[2].end_ms) == (9000, 9600)


def test_ids_by_first_appearance_not_label():
    turns = build_turns([seg(0, 1, (" a", 0, 1)), seg(1, 2, (" b", 1, 2))],
                        [DiarSeg(0, 1000, "SPEAKER_09"), DiarSeg(1000, 2000, "SPEAKER_00")])
    assert [t.speaker for t in turns] == ["S1", "S2"]


def test_largest_overlap_wins_and_nearest_when_none():
    diar = [DiarSeg(0, 1000, "A"), DiarSeg(900, 3000, "B"), DiarSeg(5000, 6000, "C")]
    turns = build_turns([seg(0, 4.2, (" x", 0.5, 0.95), (" y", 0.95, 2.0), (" z", 4.0, 4.2))], diar)
    # x overlaps A by 450 ms and B by 50 ms; y overlaps B most; z (4.0-4.2) overlaps none, B is
    # 1000 ms away and C 800 ms away
    assert [(t.speaker, t.items[0]) for t in turns] == [("S1", "x"), ("S2", "y"), ("S3", "z")]


def test_no_diarization_means_one_speaker():
    turns = build_turns(SEGS, [])
    assert {t.speaker for t in turns} == {"S1"}


def test_segment_without_words_is_one_piece():
    turns = build_turns([Segment(0.0, 1.0, " whole segment")], [DiarSeg(0, 1000, "A")])
    assert turns[0].items == ["whole segment"]


def test_pause_inside_turn_and_labels():
    s = [seg(0, 12, (" one", 0, 1), (" two", 2.5, 3), (" three", 7, 8), (" four", 8.2, 9))]
    turns = build_turns(s, [DiarSeg(0, 12000, "A")])
    items = turns[0].items
    assert items[0] == "one" and items[1].ms == 1500 and items[2] == "two"
    assert items[3].ms == 4000 and items[4] == "three four"
    assert pause_label(1000) == "(..)" and pause_label(2999) == "(..)"
    assert pause_label(3000) == "(3 s pause)" and pause_label(3500) == "(4 s pause)"


def test_gaps_under_one_second_are_not_marked():
    s = [seg(0, 2, (" a", 0, 0.5), (" b", 1.4, 2))]
    assert build_turns(s, [DiarSeg(0, 2000, "A")])[0].items == ["a b"]


def test_clock():
    assert clock(0) == "00:00:00" and clock(3_723_999) == "01:02:03"


# --- the page --------------------------------------------------------------------------------

def page(**kw):
    return render_html(SEGS, DIAR, chunks((0, 2.4), (4.0, 5.2), (9.0, 9.6)), opts(**kw))


def test_page_is_well_formed_xml_after_doctype():
    text = page()
    assert text.startswith("<!DOCTYPE html>\n")
    root = parse(text)
    assert root.tag == "html"
    # and without our helper
    ET.fromstring(text.split("\n", 1)[1])


def test_head_meta_and_csp():
    root = parse(page(transcript_start_ms=250))
    head = root.find("head")
    metas = {m.get("name"): m.get("content") for m in head.iter("meta") if m.get("name")}
    assert metas["generator"] == "LiteEcho 0.3.0"
    assert metas["liteecho:format"] == "1"
    assert metas["liteecho:audio"] == "/a/talk.m4a"
    assert metas["liteecho:language"] == "en"
    assert metas["liteecho:language-mode"] == "fixed"
    assert metas["liteecho:speakers"] == "2"
    assert metas["liteecho:speakers-mode"] == "auto"
    assert metas["liteecho:duration-ms"] == "20000"
    assert metas["liteecho:created"] == "2026-01-02T03:04:05Z"
    csp = [m for m in head.iter("meta") if m.get("http-equiv") == "Content-Security-Policy"]
    assert len(csp) == 1 and csp[0].get("content") == CSP
    assert len(list(root.iter("style"))) == 1
    assert not list(root.iter("script"))
    assert root.get("lang") == "en" and root.get("dir") == "ltr"


def test_body_structure():
    root = parse(page(transcript_start_ms=250))
    header = root.find("body/header")
    assert header.get("class") == "doc"
    assert header.find("h1").text == "talk"
    assert header.find("p").text == "talk.m4a · 00:00:20 · English · 2 speakers"
    lis = header.findall("ul/li")
    assert [li.get("data-speaker") for li in lis] == ["S1", "S2"]
    assert [li.find("span").text for li in lis] == ["S1", "S2"]
    turns = root.findall("body/main/section")
    assert [t.get("data-speaker") for t in turns] == ["S1", "S2", "S1"]
    first = turns[0]
    assert (first.get("data-start-ms"), first.get("data-end-ms")) == ("250", "2650")
    h2 = first.find("h2")
    span, time = h2.findall("span")[0], h2.find("time")
    assert span.get("class") == "speaker" and span.text == "S1"
    assert time.get("data-ms") == "250" and time.text == "00:00:00"
    p = first.find("p")
    assert p.text == "Hello there. How are you? "
    pause = p.find("span")
    assert pause.get("class") == "pause" and pause.get("data-ms") == "1600" and pause.text == "(..)"
    assert turns[1].find("p/span").text == "(4 s pause)"
    assert root.find("body/footer/p").text == "Transcribed with LiteEcho 0.3.0"


def test_speaker_colours_in_style_block_only():
    text = page()
    style = re.search(r"<style>(.*?)</style>", text, re.S)[1]
    assert '[data-speaker="S1"]' in style and '[data-speaker="S2"]' in style
    assert "prefers-color-scheme: dark" in style and "@media print" in style
    assert ' style="' not in text


def test_palette_cycles_after_eight():
    many = [seg(i, i + 1, (f" w{i}", i, i + 0.5)) for i in range(10)]
    diar = [DiarSeg(i * 1000, i * 1000 + 900, f"L{i}") for i in range(10)]
    text = render_html(many, diar, [], opts())
    style = re.search(r"<style>(.*?)</style>", text, re.S)[1]
    c1 = re.search(r'\[data-speaker="S1"\]\{--c:(#\w+)\}', style)[1]
    c9 = re.search(r'\[data-speaker="S9"\]\{--c:(#\w+)\}', style)[1]
    assert c1 == c9


@pytest.mark.parametrize("code,dir_", [("he", "rtl"), ("ar", "rtl"), ("fa", "rtl"), ("ur", "rtl"),
                                       ("yi", "rtl"), ("en", "ltr"), ("de", "ltr")])
def test_direction(code, dir_):
    root = parse(page(language=code))
    assert root.get("lang") == code and root.get("dir") == dir_


def test_one_speaker_singular():
    text = render_html([seg(0, 1, (" a", 0, 1))], [], [], opts(language="he"))
    assert "· Hebrew · 1 speaker<" in text


def test_empty_transcript_still_valid():
    root = parse(render_html([], [], [], opts(language="")))
    assert root.get("lang") == "und"
    assert root.findall("body/main/section") == []


HOSTILE = ['<img src=x onerror=alert(1)>', '"><script>alert(1)</script>', "a & b 'q'", "</p></main>"]


@pytest.mark.parametrize("bad", HOSTILE)
def test_everything_is_escaped(bad):
    s = [seg(0, 1, (" " + bad, 0, 1))]
    text = render_html(s, [], [], opts(title=bad, audio_path=f"/x/{bad}.m4a"))
    root = parse(text)  # still well-formed
    assert not list(root.iter("script")) and not list(root.iter("img"))
    assert root.find("head/title").text == bad
    assert root.find("body/header/h1").text == bad
    assert root.find("body/main/section/p").text == " ".join(bad.split())
    assert {m.get("content") for m in root.iter("meta")} >= {f"/x/{bad}.m4a"}
    assert "<script" not in text and "<img" not in text


def test_only_xml_entities_are_used():
    text = render_html([seg(0, 1, ("  x © — ", 0, 1))], [], [], opts(title="a&b"))
    names = set(re.findall(r"&([a-zA-Z]+);", text))
    assert names <= {"amp", "lt", "gt", "quot", "apos"}


def test_sampled_windows_in_page_time():
    s = [seg(0, 1, (" a", 0, 1)), seg(1, 2.5, (" b", 1, 2.5), temperature=0.4)]
    w = sampled_windows(s, opts(transcript_start_ms=100))
    assert w == [{"start_ms": 1100, "end_ms": 2600, "temperature": 0.4, "text": " b"}]
