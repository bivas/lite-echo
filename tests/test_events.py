"""JSONL event shapes, checked against app/Sources/LiteEchoCore/EngineEvent.swift."""
import io
import json
import sys

import pytest

from liteecho.events import AudioEvents, EventSink, StepEvents

# EngineEvent.swift: Wire fields and EngineStage cases.
STAGES = {"convert", "segmentation", "embeddings", "transcribe", "pauses", "download"}
WIRE_FIELDS = {"type", "stage", "completed", "total", "unit", "kind", "code", "output", "sampled",
               "message", "detail"}


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


def make():
    buf, clock = io.StringIO(), Clock()
    return EventSink(buf, clock=clock), buf, clock


def lines(buf):
    return [json.loads(x) for x in buf.getvalue().splitlines()]


def test_shapes_of_every_event_type():
    sink, buf, _ = make()
    sink.stage("transcribe", 590.2, 1311.5, "s")
    sink.stage("download", 5, 10, "bytes", kind="whisper")
    sink.language("he")
    sink.done(output="/a/b.html", sampled=[{"start_ms": 1, "end_ms": 2}])
    sink.done()
    sink.error("boom", "Traceback...")
    sink.error("cancelled")
    ev = lines(buf)
    assert ev[0] == {"type": "stage", "stage": "transcribe", "completed": 590.2, "total": 1311.5, "unit": "s"}
    assert ev[1] == {"type": "stage", "stage": "download", "completed": 5, "total": 10, "unit": "bytes",
                     "kind": "whisper"}
    assert ev[2] == {"type": "language", "code": "he"}
    assert ev[3] == {"type": "done", "output": "/a/b.html", "sampled": [{"start_ms": 1, "end_ms": 2}]}
    assert ev[4] == {"type": "done"}
    assert ev[5] == {"type": "error", "message": "boom", "detail": "Traceback..."}
    assert ev[6] == {"type": "error", "message": "cancelled", "detail": None}
    for e in ev:
        assert set(e) <= WIRE_FIELDS
        if e["type"] == "stage":
            assert e["stage"] in STAGES
    assert buf.getvalue().count("\n") == len(ev)  # one object per line


def test_non_ascii_is_not_escaped_and_lines_stay_single():
    sink, buf, _ = make()
    sink.error("שגיאה\nשורה שנייה")
    assert buf.getvalue().count("\n") == 1
    assert json.loads(buf.getvalue())["message"] == "שגיאה\nשורה שנייה"


def test_throttle_keeps_first_and_final_and_limits_rate():
    sink, buf, clock = make()
    for i in range(0, 101):  # 100 updates within 0.5 s
        clock.t = i * 0.005
        sink.stage("transcribe", i, 100, "s")
    ev = lines(buf)
    assert ev[0]["completed"] == 0
    assert ev[-1]["completed"] == 100
    assert len(ev) <= 7  # 0.5 s at <= 10/s, plus first and final
    assert sum(1 for e in ev if e["completed"] == e["total"]) == 1


def test_throttle_is_per_stage_and_final_is_emitted_once():
    sink, buf, clock = make()
    sink.stage("segmentation", 1, 10, "steps")
    sink.stage("embeddings", 1, 10, "steps")  # same instant, other stage: not throttled
    sink.stage("segmentation", 10, 10, "steps")
    sink.stage("segmentation", 10, 10, "steps")  # duplicate final
    assert [(e["stage"], e["completed"]) for e in lines(buf)] == [
        ("segmentation", 1), ("embeddings", 1), ("segmentation", 10)]


def test_audio_events_adapter_matches_audiobar_call_and_finalizes():
    sink, buf, clock = make()
    with AudioEvents(sink, "convert") as bar:
        bar(0.0, 100.0)
        clock.t += 1
        bar(40.0, 100.0)
        bar(0.0, 0.0)  # ignored like AudioBar
    ev = lines(buf)
    assert [(e["completed"], e["total"], e["unit"]) for e in ev] == [(0, 100, "s"), (40, 100, "s"), (100, 100, "s")]


def test_audio_events_no_final_after_failure():
    sink, buf, _ = make()
    with pytest.raises(RuntimeError):
        with AudioEvents(sink, "convert") as bar:
            bar(1.0, 10.0)
            raise RuntimeError
    assert all(e["completed"] != e["total"] for e in lines(buf))


def test_step_events_skip_instant_steps_and_finish_each_step():
    sink, buf, clock = make()
    with StepEvents(sink) as bars:
        bars("segmentation", 0, 5)
        bars("segmentation", 5, 5)
        bars("speaker_counting", None, None)
        bars("embeddings", 1, 4)
        clock.t += 1
        bars("embeddings", 2, 4)
        bars("discrete_diarization", None, None)
    got = [(e["stage"], e["completed"], e["total"], e["unit"]) for e in lines(buf)]
    assert got == [("segmentation", 0, 5, "steps"), ("segmentation", 5, 5, "steps"),
                   ("embeddings", 1, 4, "steps"), ("embeddings", 2, 4, "steps"),
                   ("embeddings", 4, 4, "steps")]


def test_default_stream_is_current_stdout(capsys):
    EventSink().language("en")
    assert json.loads(capsys.readouterr().out) == {"type": "language", "code": "en"}


def test_cli_events_mode_errors_are_events(tmp_path, monkeypatch, capsys):
    import liteecho.resources as res
    from liteecho.cli import main
    audio = tmp_path / "a.m4a"
    audio.write_bytes(b"x")
    monkeypatch.setenv("LITEECHO_CACHE", str(tmp_path / "empty-cache"))
    monkeypatch.delenv("LITEECHO_MODELS", raising=False)
    assert main([str(audio), "--events", "jsonl"]) == 1
    out = capsys.readouterr()
    ev = [json.loads(x) for x in out.out.splitlines()]
    assert len(ev) == 1 and ev[0]["type"] == "error" and "fetch-models" in ev[0]["message"]
    assert "usage" not in out.out.lower()

    with pytest.raises(SystemExit) as info:
        main([str(tmp_path / "missing.m4a"), "--events", "jsonl"])
    assert info.value.code == 1
    ev = [json.loads(x) for x in capsys.readouterr().out.splitlines()]
    assert ev[0]["type"] == "error" and "not found" in ev[0]["message"]


def _fake_pipeline(monkeypatch, tmp_path, fail=None):
    """Patch the CLI's heavy parts; returns the audio path."""
    import liteecho.audio as audio_mod
    import liteecho.resources as res
    import liteecho.transcribe as tr
    import liteecho.workers as workers
    from liteecho.models import DiarSeg, Segment

    class P:
        whisper_dir = pyannote_dir = prompts_dir = tmp_path

    monkeypatch.setattr(res, "resolve", lambda models_dir=None, whisper_dir=None, pyannote_dir=None: P())

    def convert(path, output_path=None, on_progress=None):
        on_progress(0.0, 10.0)
        on_progress(10.0, 10.0)
        return output_path, 0

    def run(target, kwargs, progress_kw=None, on_progress=None):
        if fail:
            raise workers.WorkerError("ValueError: kaput", "Traceback (most recent call last):\nValueError: kaput\n")
        if target.endswith("diarize"):
            on_progress("segmentation", 0, 2)
            on_progress("segmentation", 2, 2)
            on_progress("speaker_counting", None, None)
            return [DiarSeg(0, 9000, "SPEAKER_00")]
        on_progress(5.0, 10.0)
        return [Segment(0.0, 4.0, " hello", temperature=0.4)], "en"

    monkeypatch.setattr(audio_mod, "convert_to_wav", convert)
    monkeypatch.setattr(workers, "run_isolated", run)
    monkeypatch.setattr(tr, "speech_chunks", lambda wav, thr: ([{"start": 0, "end": 64000}], 10.0))
    audio = tmp_path / "talk.m4a"
    audio.write_bytes(b"x")
    return audio


def test_cli_events_full_run_emits_only_json_on_stdout(tmp_path, monkeypatch, capsys):
    from liteecho.cli import main
    import tempfile
    audio = _fake_pipeline(monkeypatch, tmp_path)
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    monkeypatch.setattr(tempfile, "tempdir", str(scratch))
    out_dir = tmp_path / "out"
    assert main([str(audio), "--events", "jsonl", "--output-folder", str(out_dir)]) == 0
    cap = capsys.readouterr()
    ev = [json.loads(x) for x in cap.out.splitlines()]  # every stdout line parses
    stages = [e["stage"] for e in ev if e["type"] == "stage"]
    assert stages[0] == "convert" and stages[-1] == "pauses"
    assert set(stages) == {"convert", "segmentation", "transcribe", "pauses"}
    assert {"type": "language", "code": "en"} in ev
    speakers = [e for e in ev if e["type"] == "speakers"]
    assert len(speakers) == 1 and speakers[0]["count"] >= 1
    # reported after diarization, before transcription starts
    names = [e.get("stage", e["type"]) for e in ev]
    assert names.index("speakers") < names.index("transcribe")
    assert ev[-1]["type"] == "done"
    assert ev[-1]["output"] == str(out_dir / "talk.html") and (out_dir / "talk.html").exists()
    assert ev[-1]["sampled"] == [{"start_ms": 0, "end_ms": 4000}]
    pauses = [e for e in ev if e.get("stage") == "pauses"]
    assert pauses[-1]["completed"] == pauses[-1]["total"] == 10
    assert "%|" not in cap.err  # no tqdm bars
    assert list(scratch.iterdir()) == []  # temp wav removed


def test_cli_events_worker_error_is_error_event(tmp_path, monkeypatch, capsys):
    from liteecho.cli import main
    audio = _fake_pipeline(monkeypatch, tmp_path, fail=True)
    assert main([str(audio), "--events", "jsonl"]) == 1
    ev = [json.loads(x) for x in capsys.readouterr().out.splitlines()]
    assert ev[-1]["type"] == "error"
    assert "kaput" in ev[-1]["message"] and "Traceback" in ev[-1]["detail"]
    assert not any(e["type"] == "done" for e in ev)


def test_sampled_report_still_works_without_events(tmp_path, monkeypatch, capsys):
    from liteecho.cli import main
    audio = _fake_pipeline(monkeypatch, tmp_path)
    rep = tmp_path / "rep.json"
    assert main([str(audio), "--sampled-report", str(rep), "--output-folder", str(tmp_path)]) == 0
    assert json.loads(rep.read_text())[0]["start_ms"] == 0
    assert capsys.readouterr().out == ""


def test_speakers_event_shape(capsys):
    EventSink().speakers(3)
    assert json.loads(capsys.readouterr().out) == {"type": "speakers", "count": 3}
