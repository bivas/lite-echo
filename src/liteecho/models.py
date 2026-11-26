"""Shared data types for LiteEcho."""
from __future__ import annotations

from dataclasses import dataclass, field

from liteecho import __version__


@dataclass
class Word:
    word: str
    start: float
    end: float
    prob: float | None = None


@dataclass
class Segment:
    """A faster-whisper segment. Times in seconds (relative to the converted audio)."""
    start: float
    end: float
    text: str
    words: list[Word] = field(default_factory=list)
    # Decoding temperature faster-whisper finally used. > 0 means its temperature fallback
    # sampled the text at random, so it can differ between runs.
    temperature: float = 0.0


@dataclass(frozen=True)
class DiarSeg:
    """A pyannote speaker turn. Times in integer milliseconds; label like 'SPEAKER_01'."""
    start_ms: int
    end_ms: int
    label: str


@dataclass
class RenderOptions:
    """What the transcript page needs besides the segments (see docs/transcript-format.md)."""
    title: str                     # shown as <title> and <h1>; normally the audio file stem
    audio_path: str                # absolute path of the input audio
    language: str                  # code used for transcription (detected or chosen)
    language_mode: str = "auto"    # "auto" | "fixed"
    speakers_mode: str = "auto"    # "auto" | "exact:N" | "range:MIN-MAX"
    duration_ms: int = 0           # audio length
    created: str | None = None     # ISO-8601 UTC; None = now
    transcript_start_ms: int = 0   # offset of the first decoded frame; added to every time shown
    app_version: str = field(default_factory=lambda: __version__)
