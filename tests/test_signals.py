import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

from liteecho.signals import Cancelled, sigterm_as_exception
from liteecho.workers import run_isolated

HERE = Path(__file__).parent


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # a zombie still answers kill(0)
    r = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
    return bool(r.stdout.strip()) and not r.stdout.strip().startswith("Z")


def _wait(cond, timeout=20.0):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.05)
    return False


def test_sigterm_becomes_cancelled_exception_and_handler_is_restored():
    before = signal.getsignal(signal.SIGTERM)
    with pytest.raises(Cancelled):
        with sigterm_as_exception():
            os.kill(os.getpid(), signal.SIGTERM)
            time.sleep(1)
    assert signal.getsignal(signal.SIGTERM) == before
    assert issubclass(Cancelled, KeyboardInterrupt)


def test_run_isolated_terminates_child_when_parent_side_raises(tmp_path):
    pidfile = tmp_path / "pid"

    # Raise from the parent side while the worker sleeps: deliver a KeyboardInterrupt via SIGALRM.
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        signal.setitimer(signal.ITIMER_REAL, 4.0)
        t0 = time.time()
        with pytest.raises(KeyboardInterrupt):
            run_isolated("_worker_helpers.sleepy", {"pidfile": str(pidfile)})
        assert time.time() - t0 < 15  # not the 60 s the worker would sleep
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, signal.SIG_DFL)
    pid = int(pidfile.read_text())
    assert _wait(lambda: not _alive(pid), 5)


def _env():
    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join([str(HERE)] + ([env["PYTHONPATH"]] if env.get("PYTHONPATH") else []))
    return env


def test_cli_sigterm_cleans_up_and_reports_cancelled(tmp_path):
    audio = tmp_path / "talk.m4a"
    audio.write_bytes(b"x")
    state = tmp_path / "state"
    state.mkdir()
    proc = subprocess.Popen(
        [sys.executable, str(HERE / "_cli_slow_main.py"), str(state), str(audio), "--events", "jsonl"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=_env())
    try:
        assert _wait(lambda: (state / "child.pid").exists() and (state / "child.pid").read_text())
        child = int((state / "child.pid").read_text())
        wav = Path((state / "wav").read_text())
        assert wav.exists() and _alive(child)
        proc.send_signal(signal.SIGTERM)
        out, err = proc.communicate(timeout=30)
    finally:
        if proc.poll() is None:
            proc.kill()
    assert proc.returncode == 143, err
    lines = [json.loads(line) for line in out.splitlines()]
    assert lines[-1] == {"type": "error", "message": "cancelled", "detail": None}
    assert all(line["type"] in {"stage", "error"} for line in lines)
    assert not wav.exists()
    assert _wait(lambda: not _alive(child), 5)


def test_worker_exits_when_parent_is_killed(tmp_path):
    state = tmp_path / "state"
    state.mkdir()
    audio = tmp_path / "talk.m4a"
    audio.write_bytes(b"x")
    proc = subprocess.Popen(
        [sys.executable, str(HERE / "_cli_slow_main.py"), str(state), str(audio)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=_env())
    child = None
    try:
        assert _wait(lambda: (state / "child.pid").exists() and (state / "child.pid").read_text())
        child = int((state / "child.pid").read_text())
        proc.kill()  # SIGKILL: no cleanup runs in the parent
        proc.wait()
        assert _wait(lambda: not _alive(child), 10), "worker outlived its parent"
    finally:
        if proc.poll() is None:
            proc.kill()
        if child and _alive(child):
            os.kill(child, signal.SIGKILL)
