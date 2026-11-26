"""Run a pipeline stage in its own spawned process.

pyannote and faster-whisper each run in a separate `spawn` subprocess. Running them in
one process is not equivalent: state left behind by torch/pyannote changes whisper's output
in near-silent passages. Each stage therefore gets a fresh interpreter here too.
"""
from __future__ import annotations

import importlib
import multiprocessing as mp
import os
import queue
import threading
import time
import traceback
from typing import Any, Callable


class WorkerError(RuntimeError):
    def __init__(self, message: str, child_traceback: str):
        super().__init__(message)
        self.child_traceback = child_traceback


def _watch_parent(parent_pid: int, interval: float = 1.0) -> None:
    """Exit this worker if the process that spawned it disappears (e.g. it was SIGKILLed)."""
    while True:
        time.sleep(interval)
        if os.getppid() != parent_pid:
            os._exit(1)


def _entry(target: str, kwargs: dict, progress_kw: str | None, q, parent_pid: int | None = None) -> None:
    if parent_pid is not None:
        threading.Thread(target=_watch_parent, args=(parent_pid,), daemon=True).start()
    try:
        module_name, func_name = target.rsplit(".", 1)
        func = getattr(importlib.import_module(module_name), func_name)
        if progress_kw:
            kwargs[progress_kw] = lambda *args: q.put(("progress", args))
        q.put(("result", func(**kwargs)))
    except BaseException as exc:  # report everything, including KeyboardInterrupt
        q.put(("error", f"{type(exc).__name__}: {exc}", traceback.format_exc()))


def run_isolated(target: str, kwargs: dict, *, progress_kw: str | None = None,
                 on_progress: Callable[..., None] | None = None) -> Any:
    """Call `target` ("package.module.function") with `kwargs` in a spawned process.

    If `progress_kw` is given, the child passes a callback under that keyword argument;
    its calls are forwarded to `on_progress` in this process. Returns the function's result
    (must be picklable) or raises WorkerError with the child's traceback.
    """
    ctx = mp.get_context("spawn")
    q = ctx.Queue()
    proc = ctx.Process(target=_entry, args=(target, dict(kwargs), progress_kw, q, os.getpid()), daemon=True)
    proc.start()
    finished = False  # the child delivered its outcome (or is already gone)
    try:
        while True:
            try:
                msg = q.get(timeout=0.2)
            except queue.Empty:
                if proc.is_alive():
                    continue
                try:  # the child may have exited right after putting its last message
                    msg = q.get(timeout=1.0)
                except queue.Empty:
                    finished = True
                    raise WorkerError(f"{target} worker exited unexpectedly "
                                      f"(exit code {proc.exitcode})", "") from None
            kind = msg[0]
            if kind == "progress":
                if on_progress is not None:
                    on_progress(*msg[1])
            elif kind == "result":
                finished = True
                return msg[1]
            else:
                finished = True
                raise WorkerError(msg[1], msg[2])
    finally:
        if finished:
            proc.join(timeout=10)
        # Not finished means this side was interrupted (SIGTERM / Ctrl-C / a failing callback):
        # stop the child at once instead of letting it keep working.
        if proc.is_alive():
            proc.terminate()
            proc.join(timeout=5)
            if proc.is_alive():
                proc.kill()
                proc.join()
