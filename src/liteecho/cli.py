from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path


MAX_SPEAKERS = 20


def _language(value: str) -> str:
    from liteecho import languages
    if value.strip().lower() == "auto":
        return "auto"
    code = languages.lookup(value)
    if code is None:
        raise argparse.ArgumentTypeError(
            f"invalid language {value!r}: use 'auto' or a Whisper language code or English name "
            "(see `liteecho engine-info --json`)")
    return code


def _count(flag: str):
    def parse(value: str) -> int:
        v = value.strip()
        if not v.isdigit() or not 1 <= int(v) <= MAX_SPEAKERS:
            raise argparse.ArgumentTypeError(
                f"invalid {flag} {value!r}: must be a whole number from 1 to {MAX_SPEAKERS}")
        return int(v)
    return parse


def _speakers(value: str) -> str:
    if value.strip().lower() == "auto":
        return "auto"
    try:
        return str(_count("--speakers")(value))
    except argparse.ArgumentTypeError:
        raise argparse.ArgumentTypeError(
            f"invalid --speakers {value!r}: must be 'auto' or a whole number from 1 to {MAX_SPEAKERS}") from None


def speaker_settings(args) -> tuple[dict, str]:
    """(diarize kwargs, speakers-mode meta value). Raises ValueError on a bad combination."""
    lo, hi = args.min_speakers, args.max_speakers
    if lo is not None or hi is not None:
        if args.speakers != "auto":
            raise ValueError("--speakers N can't be combined with --min-speakers/--max-speakers")
        lo = 1 if lo is None else lo
        hi = MAX_SPEAKERS if hi is None else hi
        if lo > hi:
            raise ValueError(f"--min-speakers ({lo}) is larger than --max-speakers ({hi})")
        return {"min_speakers": lo, "max_speakers": hi}, f"range:{lo}-{hi}"
    if args.speakers != "auto":
        return {"num_speakers": int(args.speakers)}, f"exact:{args.speakers}"
    return {}, "auto"


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="liteecho",
                                description="Transcribe audio to an HTML transcript.",
                                epilog="Download the models once with: liteecho fetch-models")
    p.add_argument("input", help="audio file (.m4a or anything PyAV can read)")
    p.add_argument("--output-folder", default=None,
                   help="output folder (default: the input file's folder); file is <stem>.html")
    p.add_argument("--language", type=_language, default="auto",
                   help="'auto' or any Whisper language code or English name, e.g. he, en, "
                        "German (default: auto)")
    p.add_argument("--speakers", type=_speakers, default="auto",
                   help=f"'auto' or the exact number of speakers, 1-{MAX_SPEAKERS} (default: auto)")
    p.add_argument("--min-speakers", type=_count("--min-speakers"), default=None, metavar="MIN",
                   help="at least this many speakers (1-20); not with --speakers N")
    p.add_argument("--max-speakers", type=_count("--max-speakers"), default=None, metavar="MAX",
                   help="at most this many speakers (1-20); not with --speakers N")
    p.add_argument("--models-dir", default=os.environ.get("LITEECHO_MODELS") or None,
                   help="models folder layout (models/precise, pyannote/). "
                        "Default: $LITEECHO_MODELS, else models from `liteecho fetch-models`, "
                        "else none")
    p.add_argument("--whisper-dir", default=os.environ.get("LITEECHO_WHISPER_DIR") or None,
                   help="the whisper model's own folder (model.bin, config.json, ...). "
                        "Overrides --models-dir for whisper. Default: $LITEECHO_WHISPER_DIR")
    p.add_argument("--pyannote-dir", default=os.environ.get("LITEECHO_PYANNOTE_DIR") or None,
                   help="the pyannote model's own folder (config.yaml, segmentation/, ...). "
                        "Overrides --models-dir for diarization. Default: $LITEECHO_PYANNOTE_DIR")
    p.add_argument("--events", choices=["jsonl"], default=None,
                   help="machine-readable mode: no progress bars, stdout carries only JSON event "
                        "lines (stage/speakers/language/done/error); logs stay on stderr")
    # Test hook: JSON list of segments decoded by random sampling (see render.sampled_windows).
    p.add_argument("--sampled-report", default=None, help=argparse.SUPPRESS)
    return p


def _events_requested(argv: list[str]) -> bool:
    return any(a == "--events=jsonl" or (a == "--events" and i + 1 < len(argv) and argv[i + 1] == "jsonl")
               for i, a in enumerate(argv))


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else list(argv)
    if argv and argv[0] == "fetch-models":
        from liteecho.fetch import main as fetch_main
        return fetch_main(argv[1:])
    if argv and argv[0] == "engine-info":
        from liteecho.info import main as info_main
        return info_main(argv[1:])
    if argv and argv[0] == "rename-speakers":
        from liteecho.rename import main as rename_main
        return rename_main(argv[1:])

    from liteecho.events import EventSink
    from liteecho.signals import Cancelled, sigterm_as_exception

    sink = EventSink() if _events_requested(argv) else None
    parser = build_parser()
    if sink is not None:
        def _error(message: str):
            print(f"liteecho: error: {message}", file=sys.stderr)
            sink.error(message, None)
            raise SystemExit(1)
        parser.error = _error  # type: ignore[method-assign]
    args = parser.parse_args(argv)
    try:
        args.diarize_kwargs, args.speakers_mode = speaker_settings(args)
    except ValueError as exc:
        parser.error(str(exc))

    try:
        with sigterm_as_exception():
            return _run(args, parser, sink)
    except KeyboardInterrupt as exc:  # Ctrl-C or SIGTERM; `finally` blocks in _run have run
        print("liteecho: cancelled", file=sys.stderr)
        if sink:
            sink.error("cancelled", None)
        return 143 if isinstance(exc, Cancelled) else 130


def _run(args, parser: argparse.ArgumentParser, sink) -> int:
    from liteecho.resources import ModelsNotFound, resolve
    from liteecho.workers import WorkerError

    def fail(message: str, detail: str | None = None) -> int:
        print(f"liteecho: error: {message}", file=sys.stderr)
        if sink:
            sink.error(message, detail)
        return 1

    inp = Path(args.input).expanduser()
    if not inp.is_file():
        parser.error(f"input file not found: {args.input}")
    inp = inp.resolve()
    try:
        paths = resolve(args.models_dir, args.whisper_dir, args.pyannote_dir)
    except ModelsNotFound as exc:
        if sink:
            return fail(str(exc))
        parser.exit(2, f"liteecho: error: {exc}\n")
    out_dir = Path(args.output_folder).expanduser() if args.output_folder else inp.parent
    language = None if args.language == "auto" else args.language

    wav = None
    try:
        # Heavy imports after argument validation.
        from liteecho.audio import convert_to_wav
        from liteecho.models import RenderOptions
        from liteecho.progress import AudioBar, StepBars, log
        from liteecho.render import render_html, sampled_windows
        from liteecho.transcribe import speech_chunks
        from liteecho.workers import run_isolated
        from liteecho.events import AudioEvents, StepEvents

        def audio_progress(stage: str, desc: str):
            return AudioEvents(sink, stage) if sink else AudioBar(desc)

        out_dir.mkdir(parents=True, exist_ok=True)
        out_file = out_dir / f"{inp.stem}.html"

        # Created here (not inside convert_to_wav) so a cancel during conversion still removes it.
        fd, wav = tempfile.mkstemp(prefix="liteecho_", suffix=".wav")
        os.close(fd)
        with audio_progress("convert", "Converting audio") as bar:
            _, start_ms = convert_to_wav(str(inp), output_path=wav, on_progress=bar)
        # Diarization and transcription each run in a fresh process (see workers.py).
        with (StepEvents(sink) if sink else StepBars()) as bars:
            diar = run_isolated(
                "liteecho.diarize.diarize",
                dict(audio_path=wav, pipeline_dir=str(paths.pyannote_dir), **args.diarize_kwargs),
                progress_kw="on_step", on_progress=bars)
        speaker_count = len({seg.label for seg in diar})
        if sink:
            sink.speakers(speaker_count)
        if "num_speakers" not in args.diarize_kwargs:
            log(f"Detected speakers: {speaker_count}")
        if language is None:
            log("Detecting language...")
        with audio_progress("transcribe", f"Transcribing ({language or 'auto'})") as bar:
            segments, lang = run_isolated(
                "liteecho.transcribe.transcribe",
                dict(audio_path=wav, model_dir=str(paths.whisper_dir), language=language,
                     vad_threshold=0.5, cpu_threads=3,
                     prompts_dir=str(paths.prompts_dir)),
                progress_kw="on_progress", on_progress=bar)
        if sink:
            sink.language(lang or language or "")
        if language is None:
            log(f"Detected language: {lang}")
        log("Analysing pauses...")
        pause_total = getattr(bar, "total", 0.0) if sink else 0.0
        if sink and pause_total > 0:
            sink.stage("pauses", 0, pause_total, "s")
        chunks, duration = speech_chunks(wav, 0.5)
        if sink:
            sink.stage("pauses", duration, duration, "s")

        opts = RenderOptions(title=inp.stem, audio_path=str(inp), language=lang or language or "",
                             language_mode="auto" if language is None else "fixed",
                             speakers_mode=args.speakers_mode, duration_ms=int(round(duration * 1000)),
                             transcript_start_ms=start_ms)
        html = render_html(segments, diar, chunks, opts)
        out_file.write_text(html, encoding="utf-8")
        report = None
        if args.sampled_report or sink:
            report = sampled_windows(segments, opts)
        if args.sampled_report:
            Path(args.sampled_report).write_text(json.dumps(report, ensure_ascii=False, indent=1),
                                                 encoding="utf-8")
        log(f"Wrote {out_file}")
        if sink:
            sink.done(output=os.path.abspath(out_file),
                      sampled=[{"start_ms": w["start_ms"], "end_ms": w["end_ms"]} for w in report])
    except WorkerError as exc:
        log(exc.child_traceback.rstrip() or str(exc))
        return fail(str(exc), exc.child_traceback.rstrip() or None)
    except Exception as exc:
        if not sink:
            raise
        import traceback
        print(traceback.format_exc(), file=sys.stderr)
        sink.error_from_exception(exc)
        return 1
    finally:
        if wav and os.path.exists(wav):
            os.remove(wav)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
