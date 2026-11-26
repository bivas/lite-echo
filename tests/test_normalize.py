from liteecho.models import DiarSeg, RenderOptions, Segment, Word
from liteecho.normalize import compare, drop_windows, extract_turns, to_lines
from liteecho.render import render_html


def make(words, diar, **kw):
    segs = [Segment(a, b, t, [Word(t, a, b)]) for t, a, b in words]
    base = dict(title="t", audio_path="/a/t.m4a", language="he", created="2026-01-01T00:00:00Z")
    base.update(kw)
    return render_html(segs, diar, [], RenderOptions(**base))


WORDS = [(" שלום", 0, 1), (" עולם", 1, 2), (" a & b <c>", 2, 3), (" bye", 6, 7)]
DIAR = [DiarSeg(0, 2000, "A"), DiarSeg(2000, 3000, "B"), DiarSeg(5000, 8000, "A")]
DOC = make(WORDS, DIAR)


def test_extract_turns():
    turns = extract_turns(DOC)
    assert to_lines(turns) == ["S1\tשלום עולם", "S2\ta & b <c>", "S1\tbye"]
    assert (turns[1].start_ms, turns[1].end_ms) == (2000, 3000)


def test_meta_names_times_and_pause_format_ignored():
    other = make(WORDS, DIAR, title="x", audio_path="/b/x.m4a", language="en", created="2030-01-01T00:00:00Z",
                 app_version="9.9", transcript_start_ms=500, speakers_mode="exact:2")
    other = other.replace('data-speaker="S1">S1<', 'data-speaker="S1">Dana<')
    other = other.replace("(3 s pause)", "(three seconds)")
    assert other != DOC
    assert compare(DOC, other) == ""


def test_text_or_speaker_change_is_a_diff():
    assert compare(DOC, DOC.replace("עולם", "עולמי")) != ""
    swapped = make(WORDS, [DiarSeg(0, 3000, "A"), DiarSeg(5000, 8000, "B")])
    diff = compare(DOC, swapped)
    assert "S2\ta & b <c>" in diff


def test_excluded_window_hides_differences_only_inside_it():
    changed = make(WORDS[:3] + [(" thanks", 6, 7)], DIAR)
    assert compare(DOC, changed) != ""
    assert compare(DOC, changed, exclude_windows=[(6000, 10**12)]) == ""
    assert compare(DOC, make([(" other", 0, 1)] + WORDS[1:3] + [(" thanks", 6, 7)], DIAR),
                   exclude_windows=[(6000, 10**12)]) != ""


def test_drop_windows_counts_and_touching_is_kept():
    turns = extract_turns(DOC)
    kept, removed = drop_windows(turns, [(2500, 2600)])
    assert removed == 1 and [t.speaker for t in kept] == ["S1", "S1"]
    assert drop_windows(turns, [(3000, 5000)]) == (turns, 0)
