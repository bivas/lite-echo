"""Speaker diarization with pyannote."""
from __future__ import annotations

import contextlib
import os
import platform
import sys
import warnings
from typing import Callable
from pathlib import Path

from .models import DiarSeg


def load_waveform(audio_file: str):
    import soundfile
    import torch
    data, sample_rate = soundfile.read(audio_file, dtype="float32", always_2d=True)
    if data.shape[0] == 0:
        raise RuntimeError(f"{audio_file} contains no audio.")
    return torch.from_numpy(data.T).contiguous(), sample_rate  # (ch, frames)


@contextlib.contextmanager
def hide_modules(*names: str):
    """Make `import name` fail for the duration (sys.modules[name] = None)."""
    previous = {n: sys.modules.get(n) for n in names}
    for n in names:
        sys.modules[n] = None
    try:
        yield
    finally:
        for n, mod in previous.items():
            if mod is None:
                sys.modules.pop(n, None)
            else:
                sys.modules[n] = mod


def hide_speechbrain():
    return hide_modules("speechbrain")


def _import_pipeline():
    """Import pyannote without torchcodec.

    pyannote imports torchcodec only for decoding audio files; we always pass an in-memory
    waveform. Loading torchcodec pulls in the system (Homebrew) FFmpeg,
    which clashes with the FFmpeg bundled in PyAV (objc duplicate-class warnings, possible
    crashes). Hiding it makes pyannote fall back to waveform-only input; silence the
    resulting 'torchcodec is not installed correctly' warning, which is expected here.
    """
    with hide_modules("torchcodec"), warnings.catch_warnings():
        warnings.filterwarnings("ignore", message=r"[\s\S]*torchcodec is not installed correctly")
        from pyannote.audio import Pipeline
    return Pipeline


def diarize(audio_path: str, pipeline_dir: str, num_speakers: int | None = None,
            min_speakers: int | None = None, max_speakers: int | None = None,
            device: str = "auto",
            on_step: Callable[[str, int | None, int | None], None] | None = None) -> list[DiarSeg]:
    """`on_step(step_name, completed, total)` receives pyannote's progress hook calls."""
    import torch
    os.environ.setdefault("MPL_IGNORE_SYSTEM_FONTS", "1")
    os.environ.setdefault("MPLCONFIGDIR", os.path.join(
        os.path.expanduser("~/Library/Caches" if platform.system() == "Darwin" else "~/.cache"),
        "LiteEcho", "matplotlib"))
    os.environ["PYANNOTE_METRICS_ENABLED"] = "0"
    Pipeline = _import_pipeline()

    if device in ("", "auto"):
        if platform.system() == "Darwin":
            device = "mps" if platform.mac_ver()[0] >= "12.3" and torch.backends.mps.is_available() else "cpu"
        else:
            device = "cuda" if torch.cuda.is_available() and torch.cuda.device_count() > 0 else "cpu"

    with hide_speechbrain():
        pipeline = Pipeline.from_pretrained(Path(pipeline_dir))
    waveform, sample_rate = load_waveform(audio_path)
    pipeline.to(torch.device(device))

    inp = {"waveform": waveform, "sample_rate": sample_rate}
    kwargs = {}
    if num_speakers is not None:
        kwargs["num_speakers"] = num_speakers
    else:
        if min_speakers is not None:
            kwargs["min_speakers"] = min_speakers
        if max_speakers is not None:
            kwargs["max_speakers"] = max_speakers
    if on_step is not None:
        def hook(step_name, step_artifact, file=None, total=None, completed=None):
            on_step(step_name, completed, total)
        kwargs["hook"] = hook
    diarization = pipeline(inp, **kwargs)

    out = []
    for turn, speaker in diarization.speaker_diarization:
        out.append(DiarSeg(start_ms=int(turn.start * 1000), end_ms=int(turn.end * 1000), label=speaker))
    return out
