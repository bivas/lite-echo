import os

import pytest

from liteecho.workers import WorkerError, run_isolated


def test_runs_in_another_process_and_forwards_progress():
    seen = []
    res = run_isolated("_worker_helpers.count_up", {"n": 3},
                       progress_kw="on_progress", on_progress=lambda i, n: seen.append((i, n)))
    assert res["n"] == 3
    assert res["pid"] != os.getpid()
    assert seen == [(1, 3), (2, 3), (3, 3)]


def test_child_exception_is_reraised_with_traceback():
    with pytest.raises(WorkerError, match="ValueError: kaput") as info:
        run_isolated("_worker_helpers.boom", {})
    assert "raise ValueError" in info.value.child_traceback


def test_child_dying_without_result_is_reported():
    with pytest.raises(WorkerError, match="exited unexpectedly"):
        run_isolated("_worker_helpers.hard_exit", {})
