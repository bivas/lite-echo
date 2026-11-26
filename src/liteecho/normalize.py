"""Reduce a LiteEcho transcript (format v1) to what a regression test compares.

Kept: the sequence of turns, each as its speaker ID and its text with pause marks removed and
whitespace collapsed. Ignored: everything in <head>, the header and footer, display names,
timestamps and pause formatting.
"""
from __future__ import annotations

import difflib
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass


@dataclass(frozen=True)
class TurnText:
    speaker: str
    start_ms: int
    end_ms: int
    text: str


def parse(html_text: str) -> ET.Element:
    """Parse a transcript with the strict XML parser (the DOCTYPE line is dropped first)."""
    body = re.sub(r"^\s*<!DOCTYPE[^>]*>", "", html_text, count=1, flags=re.IGNORECASE)
    return ET.fromstring(body)


def _text(el: ET.Element) -> str:
    """Text of `el` without the content of pause marks."""
    parts = [el.text or ""]
    for child in el:
        if "pause" not in (child.get("class") or "").split():
            parts.append(_text(child))
        parts.append(child.tail or "")
    return "".join(parts)


def extract_turns(html_text: str) -> list[TurnText]:
    root = parse(html_text)
    out = []
    for sec in root.iter("section"):
        if "turn" not in (sec.get("class") or "").split():
            continue
        text = " ".join(" ".join(_text(p) for p in sec.iter("p")).split())
        out.append(TurnText(sec.get("data-speaker") or "", int(sec.get("data-start-ms") or 0),
                            int(sec.get("data-end-ms") or 0), text))
    return out


def drop_windows(turns: list[TurnText], windows) -> tuple[list[TurnText], int]:
    """Remove turns whose [start, end) overlaps any (start_ms, end_ms) window.

    Returns (kept turns, number removed). Touching is not overlapping.
    """
    windows = [(int(a), int(b)) for a, b in windows]
    kept = [t for t in turns if not any(t.start_ms < w1 and t.end_ms > w0 for w0, w1 in windows)]
    return kept, len(turns) - len(kept)


def to_lines(turns: list[TurnText]) -> list[str]:
    return [f"{t.speaker}\t{t.text}" for t in turns]


def compare(expected_html: str, actual_html: str, exclude_windows=()) -> str:
    """'' if speakers and text agree turn by turn, else a unified diff.

    `exclude_windows`: (start_ms, end_ms) spans ignored on both sides, e.g. segments whisper
    produced by random sampling (see liteecho.render.sampled_windows).
    """
    exp, _ = drop_windows(extract_turns(expected_html), exclude_windows)
    act, _ = drop_windows(extract_turns(actual_html), exclude_windows)
    a, b = to_lines(exp), to_lines(act)
    if a == b:
        return ""
    return "\n".join(difflib.unified_diff(a, b, "expected", "actual", lineterm="", n=2))
