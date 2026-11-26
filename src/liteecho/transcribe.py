"""Transcription with faster-whisper, plus the voice-activity pass used for pause marks."""
from __future__ import annotations

import gc
import os
from pathlib import Path
from typing import Callable

from .models import Segment, Word

SAMPLING_RATE = 16000


def transcribe(audio_path: str, model_dir: str, language: str | None,
               vad_threshold: float = 0.5, cpu_threads: int = 3, device: str = "auto",
               prompts_dir: str | None = None,
               on_progress: Callable[[float, float], None] | None = None) -> tuple[list[Segment], str]:
    """Returns (segments, language_code).

    Settings: beam_size=5, word_timestamps=True, vad_filter=True with
    VadOptions(min_silence_duration_ms=500, threshold, speech_pad_ms=50), and the language's
    prompt from prompts.yml as `hotwords` (none if the language has no entry).
    `language` None => auto-detect with model.detect_language (vad_filter=True).
    """
    from faster_whisper import WhisperModel
    from faster_whisper.audio import decode_audio
    from faster_whisper.vad import VadOptions

    model = WhisperModel(
        str(model_dir),
        device=device,
        # The saved weights are float16; ctranslate2 has no fast float16 on Apple CPUs and would
        # convert them to float32 with a warning. Asking for float32 directly is the same
        # computation without the warning. (Not "auto": that picks int8 and changes the transcript.)
        compute_type="float32",
        cpu_threads=cpu_threads,
        local_files_only=True,
    )
    vad_parameters = VadOptions(min_silence_duration_ms=500, threshold=vad_threshold, speech_pad_ms=50)

    whisper_lang = language
    if not model.model.is_multilingual and whisper_lang != "en":
        whisper_lang = "en"

    if whisper_lang is None:
        audio = decode_audio(audio_path, sampling_rate=model.feature_extractor.sampling_rate)
        try:
            whisper_lang, _prob, _ = model.detect_language(
                audio, vad_filter=True, vad_parameters=vad_parameters)
        finally:
            del audio
            gc.collect()

    from liteecho import prompts
    from liteecho.resources import package_prompts_dir
    prompt = prompts.for_language(prompts_dir or package_prompts_dir(), whisper_lang)

    segments_iter, info = model.transcribe(
        audio_path,
        language=whisper_lang,
        multilingual=False,
        beam_size=5,
        word_timestamps=True,
        hotwords=prompt,
        vad_filter=True,
        vad_parameters=vad_parameters,
    )
    out: list[Segment] = []
    for s in segments_iter:
        words = [Word(word=w.word, start=float(w.start), end=float(w.end),
                      prob=None if getattr(w, "probability", None) is None else float(w.probability))
                 for w in (s.words or [])]
        out.append(Segment(start=float(s.start), end=float(s.end), text=s.text, words=words,
                           temperature=float(s.temperature or 0.0)))
        if on_progress is not None:
            on_progress(float(s.end), float(info.duration))
    del model
    gc.collect()
    return out, whisper_lang


def speech_chunks(audio_path: str, vad_threshold: float = 0.5) -> tuple[list[dict], float]:
    """Voice activity for pause marks (speech_pad_ms=0).
    Returns (chunks with sample-index 'start'/'end' at 16 kHz, duration in seconds)."""
    from faster_whisper.audio import decode_audio
    from faster_whisper.vad import VadOptions, get_speech_timestamps

    audio_array = decode_audio(audio_path, sampling_rate=SAMPLING_RATE)
    duration = audio_array.shape[0] / SAMPLING_RATE
    vad_parameters = VadOptions(min_silence_duration_ms=500, threshold=vad_threshold, speech_pad_ms=0)
    chunks = get_speech_timestamps(audio_array, vad_parameters)
    del audio_array
    return chunks, duration
