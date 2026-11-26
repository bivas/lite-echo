"""Terminal progress bars for the CLI (stderr, auto-disabled when stderr is not a TTY)."""
from __future__ import annotations

import sys

from tqdm import tqdm

_BAR_FORMAT = "{desc:<24}{percentage:3.0f}%|{bar}| {clock} [{elapsed}<{remaining}]"
_COUNT_FORMAT = "{desc:<24}{percentage:3.0f}%|{bar}| {n_fmt}/{total_fmt} [{elapsed}<{remaining}]"


def log(msg: str) -> None:
    """Print a status line without breaking an active bar."""
    tqdm.write(msg, file=sys.stderr)


def _clock(seconds: float) -> str:
    s = max(0, int(seconds))
    h, rem = divmod(s, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


class _ClockBar(tqdm):
    """tqdm whose bar_format can use {clock}: audio position as mm:ss/mm:ss."""

    @property
    def format_dict(self):
        d = super().format_dict
        d["clock"] = f"{_clock(self.n)}/{_clock(self.total or 0)}"
        return d


class AudioBar:
    """Progress through the audio timeline, e.g. `07:41/21:51`. Use as a callback(pos_s, total_s)."""

    def __init__(self, desc: str):
        self.desc = desc
        self.bar: tqdm | None = None

    def __call__(self, pos_s: float, total_s: float) -> None:
        if total_s <= 0:
            return
        if self.bar is None:
            self.bar = _ClockBar(total=total_s, desc=self.desc, file=sys.stderr, disable=None,
                            bar_format=_BAR_FORMAT, dynamic_ncols=True, leave=True)
        pos_s = min(max(pos_s, 0.0), total_s)
        self.bar.update(pos_s - self.bar.n)  # update() keeps tqdm's rate limiting and ETA

    def close(self) -> None:
        if self.bar is not None:
            self.bar.n = self.bar.total
            self.bar.refresh()
            self.bar.close()
            self.bar = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


class StepBars:
    """One bar per pyannote step. Use as a callback(step_name, completed, total)."""

    LABELS = {"segmentation": "Speakers: segmentation", "embeddings": "Speakers: embeddings"}

    def __init__(self):
        self.step: str | None = None
        self.bar: tqdm | None = None

    def __call__(self, step: str, completed: int | None, total: int | None) -> None:
        if step not in self.LABELS:  # instant steps (speaker_counting, discrete_diarization)
            return
        if step != self.step:
            self.close()
            self.step = step
            self.bar = tqdm(total=total or 1, desc=self.LABELS[step], file=sys.stderr, disable=None,
                            bar_format=_COUNT_FORMAT, dynamic_ncols=True, leave=True)
        if self.bar is None:
            return
        if total:
            self.bar.total = total
        self.bar.n = self.bar.total if completed is None else completed
        self.bar.refresh()

    def close(self) -> None:
        if self.bar is not None:
            self.bar.n = self.bar.total
            self.bar.refresh()
            self.bar.close()
            self.bar = None
        self.step = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
