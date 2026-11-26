import io
import sys

from liteecho import progress
from liteecho.progress import AudioBar, StepBars, _clock


def test_clock_format():
    assert _clock(0) == "00:00"
    assert _clock(61.9) == "01:01"
    assert _clock(1311) == "21:51"
    assert _clock(3725) == "1:02:05"
    assert _clock(-3) == "00:00"


def test_bars_are_silent_when_stderr_is_not_a_tty(monkeypatch):
    fake = io.StringIO()  # StringIO.isatty() is False -> tqdm(disable=None) disables itself
    monkeypatch.setattr(sys, "stderr", fake)
    with AudioBar("Transcribing") as bar:
        bar(10.0, 60.0)
        bar(70.0, 60.0)  # clamped, must not raise
    with StepBars() as steps:
        steps("segmentation", 0, 10)
        steps("segmentation", 10, 10)
        steps("speaker_counting", None, None)  # instant steps are ignored
        steps("embeddings", 3, 5)
    assert fake.getvalue() == ""


def test_audiobar_ignores_unknown_total():
    bar = AudioBar("x")
    bar(5.0, 0.0)
    assert bar.bar is None
    bar.close()


def test_log_goes_to_stderr(capsys):
    progress.log("hello")
    assert capsys.readouterr().err == "hello\n"
