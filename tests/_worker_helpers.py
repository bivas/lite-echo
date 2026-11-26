"""Importable targets for test_workers.py (spawned children import these by name)."""
import os


def count_up(n, on_progress=None):
    for i in range(1, n + 1):
        if on_progress is not None:
            on_progress(i, n)
    return {"pid": os.getpid(), "n": n}


def boom():
    raise ValueError("kaput")


def hard_exit():
    os._exit(3)


def sleepy(pidfile, seconds=60):
    """Record the worker's pid, then block (a stand-in for a long diarization/transcription)."""
    import time
    with open(pidfile, "w") as fh:
        fh.write(str(os.getpid()))
    time.sleep(seconds)
    return {}
