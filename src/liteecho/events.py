"""JSON-lines event stream for machine consumers (the macOS app): `--events jsonl`.

Only stdlib is imported here. stdout carries nothing but JSON objects, one per line, flushed
per line; human-readable logs stay on stderr. The wire format is documented in
docs/macos-app-plan.md ("Engine protocol").
"""
from __future__ import annotations

import json
import sys
import threading
import time
import traceback
from typing import Any, Callable, TextIO

MIN_INTERVAL_S = 0.1  # at most 10 stage events per second and stage


class EventSink:
    """Thread-safe JSONL writer with per-stage throttling."""

    def __init__(self, stream: TextIO | None = None, clock: Callable[[], float] = time.monotonic,
                 min_interval: float = MIN_INTERVAL_S):
        self._stream = stream
        self._clock = clock
        self._min_interval = min_interval
        self._lock = threading.Lock()
        self._last: dict[tuple, float] = {}
        self._finished: set[tuple] = set()

    @property
    def stream(self) -> TextIO:
        return self._stream if self._stream is not None else sys.stdout

    def emit(self, obj: dict[str, Any]) -> None:
        line = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
        with self._lock:
            stream = self.stream
            stream.write(line + "\n")
            stream.flush()

    def stage(self, stage: str, completed: float, total: float, unit: str,
              kind: str | None = None) -> None:
        """Emit a progress event. The first and the final (completed >= total) event of a stage
        always go out (the final one only once); others at most every `min_interval` seconds."""
        key = (stage, kind)
        final = total > 0 and completed >= total
        with self._lock:
            if key in self._finished:
                return
            now = self._clock()
            last = self._last.get(key)
            if not final and last is not None and now - last < self._min_interval:
                return
            self._last[key] = now
            if final:
                self._finished.add(key)
            obj: dict[str, Any] = {"type": "stage", "stage": stage,
                                   "completed": _num(completed), "total": _num(total), "unit": unit}
            if kind is not None:
                obj["kind"] = kind
            stream = self.stream
            stream.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
            stream.flush()

    def language(self, code: str) -> None:
        self.emit({"type": "language", "code": code})

    def speakers(self, count: int) -> None:
        """Number of distinct speakers diarization found (sent right after that stage)."""
        self.emit({"type": "speakers", "count": int(count)})

    def done(self, output: str | None = None, sampled: list[dict] | None = None) -> None:
        obj: dict[str, Any] = {"type": "done"}
        if output is not None:
            obj["output"] = output
        if sampled is not None:
            obj["sampled"] = sampled
        self.emit(obj)

    def error(self, message: str, detail: str | None = None) -> None:
        self.emit({"type": "error", "message": message, "detail": detail})

    def error_from_exception(self, exc: BaseException, message: str | None = None) -> None:
        detail = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))
        self.error(message or str(exc) or type(exc).__name__, detail)


def _num(x: float) -> float | int:
    return int(x) if float(x).is_integer() else round(float(x), 3)


class AudioEvents:
    """Drop-in for progress.AudioBar: callback(pos_s, total_s) -> stage events in seconds."""

    def __init__(self, sink: EventSink, stage: str):
        self.sink = sink
        self.stage = stage
        self.total = 0.0
        self.started = False

    def __call__(self, pos_s: float, total_s: float) -> None:
        if total_s <= 0:
            return
        self.total = total_s
        self.started = True
        pos_s = min(max(pos_s, 0.0), total_s)
        # A position at the very end counts as final only on close(), so the final event is exact.
        self.sink.stage(self.stage, pos_s, total_s, "s")

    def close(self) -> None:
        if self.started:
            self.sink.stage(self.stage, self.total, self.total, "s")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, *exc):
        if exc_type is None:
            self.close()


class StepEvents:
    """Drop-in for progress.StepBars: callback(step_name, completed, total)."""

    STAGES = {"segmentation", "embeddings"}

    def __init__(self, sink: EventSink):
        self.sink = sink
        self.step: str | None = None
        self.total = 1

    def __call__(self, step: str, completed: int | None, total: int | None) -> None:
        if step not in self.STAGES:  # instant steps (speaker_counting, discrete_diarization)
            return
        if step != self.step:
            self.close()
            self.step = step
            self.total = total or 1
        if total:
            self.total = total
        done = self.total if completed is None else min(completed, self.total)
        self.sink.stage(step, done, self.total, "steps")

    def close(self) -> None:
        if self.step is not None:
            self.sink.stage(self.step, self.total, self.total, "steps")
        self.step = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, *exc):
        if exc_type is None:
            self.close()
