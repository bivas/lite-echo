"""SIGTERM handling: a cancelled job unwinds like Ctrl-C so `finally` blocks run."""
from __future__ import annotations

import contextlib
import signal
import threading


class Cancelled(KeyboardInterrupt):
    """Raised in the main thread when the process receives SIGTERM."""


def _handler(signum, frame):
    # Ignore repeats so cleanup (terminating workers, removing temp files) is not interrupted.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    raise Cancelled("terminated by SIGTERM")


@contextlib.contextmanager
def sigterm_as_exception():
    """Within the block SIGTERM raises `Cancelled` (a KeyboardInterrupt). No-op off the main thread."""
    if threading.current_thread() is not threading.main_thread():
        yield
        return
    previous = signal.signal(signal.SIGTERM, _handler)
    try:
        yield
    finally:
        signal.signal(signal.SIGTERM, previous)
