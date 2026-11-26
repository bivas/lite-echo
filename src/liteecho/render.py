"""Write the transcript page (format v1, see docs/transcript-format.md).

Pipeline, all deterministic:

1. Split whisper output into pieces: one per word when word timestamps exist, else one per
   segment.
2. Give each piece the diarization speaker it overlaps longest. A piece that overlaps no speaker
   turn goes to the nearest one in time (the earlier one on a tie).
3. Consecutive pieces of one speaker form a turn. Speakers are numbered S1, S2, ... in order of
   first appearance.
4. Between consecutive pieces, the silence is the larger of the gap between their timestamps and
   the longest voice-activity silence centred between them. Silences of 1 s or more become pause
   marks; between two turns the mark ends the earlier turn.

Every value that ends up in the page passes through ``_e`` (``html.escape(..., quote=True)``)
where it is written. The result is well-formed XML after the DOCTYPE line.
"""
from __future__ import annotations

import bisect
import html
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from . import languages
from .models import DiarSeg, RenderOptions, Segment

FORMAT_VERSION = "1"
PAUSE_MIN_MS = 1000
SHORT_PAUSE_MS = 3000
VAD_RATE = 16000  # speech chunks are sample indices at this rate

CSP = "default-src 'none'; style-src 'unsafe-inline'"

# One colour per speaker, cycling. Light values are for white paper, dark ones for a dark page.
PALETTE_LIGHT = ("#1d63c9", "#c2410c", "#15803d", "#b91c1c", "#7c3aed", "#0e7490", "#a16207", "#be185d")
PALETTE_DARK = ("#7cb4ff", "#fdba74", "#86efac", "#fca5a5", "#c4b5fd", "#67e8f9", "#fde047", "#f9a8d4")


def _e(value) -> str:
    return html.escape(str(value), quote=True)


@dataclass
class Piece:
    start_ms: int
    end_ms: int
    text: str
    label: str = ""  # diarization label


@dataclass
class Pause:
    ms: int


@dataclass
class Turn:
    speaker: str              # S1, S2, ...
    start_ms: int
    end_ms: int
    items: list = field(default_factory=list)  # str runs and Pause marks, in order


# --- pieces and speakers -------------------------------------------------------------------

def _ms(seconds: float) -> int:
    return int(round(seconds * 1000))


def pieces(segments: list[Segment]) -> list[Piece]:
    out: list[Piece] = []
    for seg in segments:
        if seg.words:
            for w in seg.words:
                if w.word.strip():
                    out.append(Piece(_ms(w.start), max(_ms(w.start), _ms(w.end)), w.word))
        elif seg.text.strip():
            out.append(Piece(_ms(seg.start), max(_ms(seg.start), _ms(seg.end)), seg.text))
    out.sort(key=lambda p: (p.start_ms, p.end_ms))
    return out


class _Speakers:
    """Overlap / nearest-turn lookup over diarization segments."""

    def __init__(self, diar: list[DiarSeg]):
        self.segs = sorted(diar, key=lambda d: (d.start_ms, d.end_ms, d.label))
        self.starts = [d.start_ms for d in self.segs]
        # running maximum of end_ms and where it occurs
        self.max_end: list[int] = []
        self.max_at: list[int] = []
        best, at = -1, -1
        for i, d in enumerate(self.segs):
            if d.end_ms > best:
                best, at = d.end_ms, i
            self.max_end.append(best)
            self.max_at.append(at)

    def label(self, start: int, end: int) -> str:
        if not self.segs:
            return ""
        hi = bisect.bisect_left(self.starts, end) if end > start else bisect.bisect_right(self.starts, start)
        best_label, best_key = None, None
        i = hi - 1
        while i >= 0 and self.max_end[i] > start:
            d = self.segs[i]
            overlap = min(end, d.end_ms) - max(start, d.start_ms)
            key = (overlap, -i)  # largest overlap; on a tie the earlier segment
            if overlap > 0 and (best_key is None or key > best_key):
                best_label, best_key = d.label, key
            i -= 1
        if best_label is not None:
            return best_label
        # No overlap: nearest turn. Candidates: the one ending last before us, the first after us.
        before = self.segs[self.max_at[hi - 1]] if hi > 0 else None
        after = self.segs[hi] if hi < len(self.segs) else None
        if before is not None and before.end_ms >= start:  # touches or contains a zero-length piece
            return before.label
        if after is None:
            return before.label  # type: ignore[union-attr]
        if before is None:
            return after.label
        return before.label if start - before.end_ms <= after.start_ms - end else after.label


def _silences(chunks: list[dict], duration_ms: int) -> list[tuple[int, int]]:
    """Gaps between voice-activity chunks, in ms."""
    spans = sorted((int(c["start"] * 1000 // VAD_RATE), int(c["end"] * 1000 // VAD_RATE)) for c in chunks)
    out = []
    prev_end = 0
    for s, e in spans:
        if s > prev_end:
            out.append((prev_end, s))
        prev_end = max(prev_end, e)
    if duration_ms > prev_end and spans:
        out.append((prev_end, duration_ms))
    return out


def build_turns(segments: list[Segment], diar: list[DiarSeg], chunks: list[dict] | None = None,
                duration_ms: int = 0) -> list[Turn]:
    """Turns with speaker IDs, text runs and pause marks. Times are relative to the audio."""
    ps = pieces(segments)
    lookup = _Speakers(diar)
    for p in ps:
        p.label = lookup.label(p.start_ms, p.end_ms)

    silences = _silences(chunks or [], duration_ms)
    mids = [(a + b) / 2 for a, b in silences]

    def silence(p: Piece, q: Piece) -> int:
        gap = max(0, q.start_ms - p.end_ms)
        lo = bisect.bisect_left(mids, (p.start_ms + p.end_ms) / 2)
        hi = bisect.bisect_right(mids, (q.start_ms + q.end_ms) / 2)
        vad = max((b - a for a, b in silences[lo:hi]), default=0)
        return max(gap, vad)

    ids: dict[str, str] = {}
    turns: list[Turn] = []
    run: list[str] = []

    def flush_run():
        text = " ".join("".join(run).split())
        if text:
            turns[-1].items.append(text)
        run.clear()

    prev: Piece | None = None
    for p in ps:
        if p.label not in ids:
            ids[p.label] = f"S{len(ids) + 1}"
        speaker = ids[p.label]
        pause = silence(prev, p) if prev is not None else 0
        if not turns or turns[-1].speaker != speaker:
            if turns:
                flush_run()
                if pause >= PAUSE_MIN_MS:
                    turns[-1].items.append(Pause(pause))
            turns.append(Turn(speaker, p.start_ms, p.end_ms))
        elif pause >= PAUSE_MIN_MS:
            flush_run()
            turns[-1].items.append(Pause(pause))
        run.append(p.text)
        turns[-1].end_ms = max(turns[-1].end_ms, p.end_ms)
        prev = p
    if turns:
        flush_run()
    return turns


# --- output --------------------------------------------------------------------------------

def clock(ms: int) -> str:
    s = max(0, int(ms)) // 1000
    return f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"


def pause_label(ms: int) -> str:
    return "(..)" if ms < SHORT_PAUSE_MS else f"({int(ms / 1000 + 0.5)} s pause)"


def _css(n_speakers: int) -> str:
    light = "".join(f'[data-speaker="S{i}"]{{--c:{PALETTE_LIGHT[(i - 1) % 8]}}}'
                    for i in range(1, n_speakers + 1))
    dark = "".join(f'[data-speaker="S{i}"]{{--c:{PALETTE_DARK[(i - 1) % 8]}}}'
                   for i in range(1, n_speakers + 1))
    return f"""
:root{{color-scheme:light dark;--bg:#ffffff;--fg:#1d1d1f;--muted:#6e6e73;--rule:#e3e3e8}}
html{{background:var(--bg);color:var(--fg)}}
body{{margin:0 auto;max-width:44rem;padding:2.5rem 1.25rem 4rem;font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,"Helvetica Neue",Arial,sans-serif;-webkit-text-size-adjust:100%}}
header.doc{{border-bottom:1px solid var(--rule);margin-bottom:2rem;padding-bottom:1rem}}
h1{{font-size:1.6rem;line-height:1.25;margin:0 0 .3rem;overflow-wrap:anywhere}}
.info{{color:var(--muted);font-size:.9rem;margin:0 0 .8rem}}
ul.speakers{{display:flex;flex-wrap:wrap;gap:.3rem 1rem;list-style:none;margin:0;padding:0}}
.speaker{{color:var(--c,var(--fg));font-weight:600}}
section.turn{{border-inline-start:3px solid var(--c,var(--rule));margin:0 0 1.3rem;padding-inline-start:.9rem}}
section.turn h2{{font-size:.95rem;font-weight:400;margin:0 0 .15rem}}
time{{color:var(--muted);font-size:.85rem;font-variant-numeric:tabular-nums;margin-inline-start:.4rem}}
section.turn p{{margin:0;overflow-wrap:break-word}}
.pause{{color:var(--muted);font-size:.85em;white-space:nowrap}}
footer.doc{{border-top:1px solid var(--rule);color:var(--muted);font-size:.8rem;margin-top:3rem;padding-top:.8rem}}
{light}
@media (prefers-color-scheme: dark){{
:root{{--bg:#1c1c1e;--fg:#ececf0;--muted:#a0a0a8;--rule:#3a3a3e}}
{dark}
}}
@media print{{
:root{{--bg:#ffffff;--fg:#000000;--muted:#555555;--rule:#bbbbbb}}
{light}
body{{max-width:none;padding:0;font-size:11pt}}
section.turn{{break-inside:avoid-page}}
h2{{break-after:avoid-page}}
}}
"""


def render_html(segments: list[Segment], diar: list[DiarSeg], chunks: list[dict] | None,
                opts: RenderOptions) -> str:
    turns = build_turns(segments, diar, chunks, opts.duration_ms)
    off = int(opts.transcript_start_ms)
    speakers: list[str] = []
    for t in turns:
        if t.speaker not in speakers:
            speakers.append(t.speaker)
    n = len(speakers)
    code = opts.language or ""
    created = opts.created or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lang_name = languages.name(code) if code else "Unknown language"
    info = " · ".join([Path(opts.audio_path).name, clock(opts.duration_ms), lang_name,
                       f"{n} speaker" if n == 1 else f"{n} speakers"])

    out: list[str] = [
        "<!DOCTYPE html>",
        f'<html lang="{_e(code or "und")}" dir="{_e(languages.direction(code))}">',
        "<head>",
        '<meta charset="utf-8" />',
        f'<meta http-equiv="Content-Security-Policy" content="{CSP}" />',
        '<meta name="viewport" content="width=device-width, initial-scale=1" />',
        f'<meta name="generator" content="LiteEcho {_e(opts.app_version)}" />',
        f'<meta name="liteecho:format" content="{_e(FORMAT_VERSION)}" />',
        f'<meta name="liteecho:audio" content="{_e(opts.audio_path)}" />',
        f'<meta name="liteecho:language" content="{_e(code)}" />',
        f'<meta name="liteecho:language-mode" content="{_e(opts.language_mode)}" />',
        f'<meta name="liteecho:speakers" content="{_e(n)}" />',
        f'<meta name="liteecho:speakers-mode" content="{_e(opts.speakers_mode)}" />',
        f'<meta name="liteecho:duration-ms" content="{_e(int(opts.duration_ms))}" />',
        f'<meta name="liteecho:created" content="{_e(created)}" />',
        f"<title>{_e(opts.title)}</title>",
        f"<style>{_css(n)}</style>",
        "</head>",
        "<body>",
        '<header class="doc">',
        f"<h1>{_e(opts.title)}</h1>",
        f'<p class="info">{_e(info)}</p>',
        '<ul class="speakers">' if speakers else '<ul class="speakers"></ul>',
    ]
    if speakers:
        for s in speakers:
            out.append(f'<li data-speaker="{_e(s)}"><span class="speaker" data-speaker="{_e(s)}">{_e(s)}</span></li>')
        out.append("</ul>")
    out += ["</header>", "<main>"]
    for t in turns:
        start, end = t.start_ms + off, t.end_ms + off
        parts = []
        for item in t.items:
            if isinstance(item, Pause):
                parts.append(f'<span class="pause" data-ms="{_e(item.ms)}">{_e(pause_label(item.ms))}</span>')
            else:
                parts.append(_e(item))
        out += [
            f'<section class="turn" data-speaker="{_e(t.speaker)}" data-start-ms="{_e(start)}" data-end-ms="{_e(end)}">',
            f'<h2><span class="speaker" data-speaker="{_e(t.speaker)}">{_e(t.speaker)}</span> '
            f'<time data-ms="{_e(start)}">{_e(clock(start))}</time></h2>',
            f"<p>{' '.join(parts)}</p>",
            "</section>",
        ]
    out += ["</main>",
            f'<footer class="doc"><p>Transcribed with LiteEcho {_e(opts.app_version)}</p></footer>',
            "</body>", "</html>", ""]
    return "\n".join(out)


def sampled_windows(segments: list[Segment], opts: RenderOptions) -> list[dict]:
    """Segments whisper decoded by random sampling (temperature fallback), in page time (ms)."""
    off = int(opts.transcript_start_ms)
    return [{"start_ms": _ms(s.start) + off, "end_ms": _ms(s.end) + off,
             "temperature": s.temperature, "text": s.text}
            for s in segments if s.temperature > 0]
