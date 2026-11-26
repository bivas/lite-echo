import pytest

from liteecho.cli import build_parser


def test_sampled_report_flag_is_hidden_but_accepted(capsys):
    args = build_parser().parse_args(["x.m4a", "--sampled-report", "/tmp/r.json"])
    assert args.sampled_report == "/tmp/r.json"
    with pytest.raises(SystemExit):
        build_parser().parse_args(["--help"])
    assert "--sampled-report" not in capsys.readouterr().out


@pytest.mark.parametrize("bad", ["0", "-1", "abc", "2.5", "21"])
def test_speakers_rejects_out_of_range(bad):
    with pytest.raises(SystemExit):
        build_parser().parse_args(["x.m4a", "--speakers", bad])


@pytest.mark.parametrize("value,code", [("auto", "auto"), ("Hebrew", "he"), ("EN", "en"), ("de", "de"),
                                        ("japanese", "ja"), ("yue", "yue")])
def test_language_codes_and_names(value, code):
    assert build_parser().parse_args(["x.m4a", "--language", value]).language == code


def test_unknown_language_rejected(capsys):
    with pytest.raises(SystemExit) as info:
        build_parser().parse_args(["x.m4a", "--language", "xx"])
    assert info.value.code == 2


def _settings(*argv):
    from liteecho.cli import speaker_settings
    return speaker_settings(build_parser().parse_args(["x.m4a", *argv]))


@pytest.mark.parametrize("argv,kwargs,mode", [
    ((), {}, "auto"),
    (("--speakers", "auto"), {}, "auto"),
    (("--speakers", "3"), {"num_speakers": 3}, "exact:3"),
    (("--min-speakers", "3", "--max-speakers", "8"), {"min_speakers": 3, "max_speakers": 8}, "range:3-8"),
    (("--min-speakers", "2"), {"min_speakers": 2, "max_speakers": 20}, "range:2-20"),
    (("--max-speakers", "4"), {"min_speakers": 1, "max_speakers": 4}, "range:1-4"),
    (("--speakers", "auto", "--min-speakers", "5", "--max-speakers", "5"), {"min_speakers": 5, "max_speakers": 5}, "range:5-5"),
])
def test_speaker_settings(argv, kwargs, mode):
    assert _settings(*argv) == (kwargs, mode)


@pytest.mark.parametrize("argv", [("--min-speakers", "0"), ("--max-speakers", "21"), ("--min-speakers", "x")])
def test_speaker_bounds_rejected(argv):
    with pytest.raises(SystemExit) as info:
        build_parser().parse_args(["x.m4a", *argv])
    assert info.value.code == 2


@pytest.mark.parametrize("argv", [("--speakers", "2", "--min-speakers", "1"),
                                  ("--min-speakers", "5", "--max-speakers", "3")])
def test_bad_speaker_combinations_exit_2(argv, tmp_path, capsys):
    from liteecho.cli import main
    with pytest.raises(SystemExit) as info:
        main([str(tmp_path / "a.m4a"), *argv])
    assert info.value.code == 2
    assert "speakers" in capsys.readouterr().err


def test_bad_speaker_combination_is_error_event(tmp_path, capsys):
    import json
    from liteecho.cli import main
    with pytest.raises(SystemExit):
        main([str(tmp_path / "a.m4a"), "--speakers", "2", "--max-speakers", "4", "--events", "jsonl"])
    ev = [json.loads(x) for x in capsys.readouterr().out.splitlines()]
    assert ev[-1]["type"] == "error" and "--speakers" in ev[-1]["message"]


def test_fetch_models_subcommand_dispatches(monkeypatch):
    import liteecho.fetch as fetch
    from liteecho.cli import main
    seen = {}
    monkeypatch.setattr(fetch, "main", lambda argv: seen.setdefault("argv", argv) and 0 or 0)
    assert main(["fetch-models", "--only", "whisper"]) == 0
    assert seen["argv"] == ["--only", "whisper"]


def test_missing_models_exit_with_instructions(tmp_path, monkeypatch, capsys):
    import liteecho.resources as res
    from liteecho.cli import main
    audio = tmp_path / "a.m4a"
    audio.write_bytes(b"x")
    monkeypatch.setenv("LITEECHO_CACHE", str(tmp_path / "empty-cache"))
    monkeypatch.delenv("LITEECHO_MODELS", raising=False)
    with pytest.raises(SystemExit) as info:
        main([str(audio)])
    assert info.value.code == 2
    assert "fetch-models" in capsys.readouterr().err


def test_per_model_flags_and_env_reach_resolve(tmp_path, monkeypatch):
    import liteecho.cli as cli
    monkeypatch.delenv("LITEECHO_MODELS", raising=False)
    monkeypatch.setenv("LITEECHO_WHISPER_DIR", "/env/w")
    monkeypatch.delenv("LITEECHO_PYANNOTE_DIR", raising=False)
    args = cli.build_parser().parse_args(["a.m4a"])
    assert (args.whisper_dir, args.pyannote_dir) == ("/env/w", None)
    args = cli.build_parser().parse_args(["a.m4a", "--whisper-dir", "/f/w", "--pyannote-dir", "/f/p"])
    assert (args.whisper_dir, args.pyannote_dir) == ("/f/w", "/f/p")


def test_incomplete_per_model_dir_exits_with_missing_files(tmp_path, monkeypatch, capsys):
    from liteecho.cli import main
    audio = tmp_path / "a.m4a"
    audio.write_bytes(b"x")
    w = tmp_path / "w"
    w.mkdir()
    monkeypatch.setenv("LITEECHO_CACHE", str(tmp_path / "empty-cache"))
    monkeypatch.delenv("LITEECHO_MODELS", raising=False)
    with pytest.raises(SystemExit) as info:
        main([str(audio), "--whisper-dir", str(w)])
    assert info.value.code == 2
    err = capsys.readouterr().err
    assert "--whisper-dir" in err and "model.bin" in err
