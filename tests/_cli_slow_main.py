"""Runs the real `liteecho` CLI with a fake slow pipeline (used by test_signals.py).

argv: STATE_DIR INPUT [cli args...]. Writes STATE_DIR/wav (temp wav path) and STATE_DIR/child.pid
(the isolated worker's pid). Models are faked; conversion writes a stub; the worker sleeps.
"""
import sys
from pathlib import Path

state = Path(sys.argv[1]) if len(sys.argv) > 1 else None
argv = sys.argv[2:]

import liteecho.audio as audio
import liteecho.resources as resources
import liteecho.workers as workers
from liteecho.cli import main

real_run = workers.run_isolated


def fake_convert(input_path, output_path=None, on_progress=None):
    Path(output_path).write_bytes(b"RIFF")
    (state / "wav").write_text(str(output_path))
    if on_progress:
        on_progress(1.0, 10.0)
    return str(output_path), 0


def fake_run(target, kwargs, **kw):
    return real_run("_worker_helpers.sleepy", {"pidfile": str(state / "child.pid")})


class _P:
    whisper_dir = pyannote_dir = prompts_dir = Path("/nonexistent")


if __name__ == "__main__":  # spawned workers re-import this module as __main__-less; keep it inert
    audio.convert_to_wav = fake_convert
    workers.run_isolated = fake_run
    resources.resolve = lambda models_dir=None, whisper_dir=None, pyannote_dir=None: _P()
    raise SystemExit(main(argv))
