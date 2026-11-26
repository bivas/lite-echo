"""Audio conversion to the WAV the models read.

Output: WAV container, pcm_s16le, 16 kHz, mono, written by PyAV.
"""
from __future__ import annotations

import logging
import os
import tempfile
from collections import deque
from typing import Callable

import av

logger = logging.getLogger(__name__)

OUTPUT_FORMAT = "wav"
OUTPUT_CODEC = "pcm_s16le"
OUTPUT_RATE = 16000
OUTPUT_LAYOUT = "mono"


def convert_to_wav(input_path: str, output_path: str | None = None,
                   on_progress: Callable[[float, float], None] | None = None) -> tuple[str, int]:
    """Convert `input_path` to 16 kHz mono PCM16 WAV.

    Returns (wav_path, start_offset_ms). If `output_path` is None a temp file is created
    (caller must delete it). `on_progress(pos_s, total_s)` is called as frames are decoded.
    """
    if output_path is None:
        fd, output_path = tempfile.mkstemp(prefix="liteecho_", suffix=".wav")
        os.close(fd)

    container_in = av.open(str(input_path))
    container_out = av.open(str(output_path), mode="w", format=OUTPUT_FORMAT)
    packets_written = 0
    start_offset_ms = 0
    try:
        stream_in = container_in.streams.audio[0]
        stream_out = container_out.add_stream(OUTPUT_CODEC, rate=OUTPUT_RATE, layout=OUTPUT_LAYOUT)

        # Origin of the media timeline.
        if container_in.streams.video and container_in.start_time is not None:
            timeline_start = container_in.start_time / av.time_base
        elif stream_in.start_time is None:
            timeline_start = 0.0
        else:
            timeline_start = float(stream_in.start_time * stream_in.time_base)

        if container_in.duration is not None:
            total_s = container_in.duration / av.time_base
        elif stream_in.duration is not None:
            total_s = float(stream_in.duration * stream_in.time_base)
        else:
            total_s = 0.0

        first_frame = True
        decode_errors = 0
        pending: deque = deque()
        for packet in container_in.demux(stream_in):
            try:
                pending.extend(packet.decode())
            except av.error.InvalidDataError as exc:
                decode_errors += 1
                logger.warning("Skipping invalid audio packet %s while decoding %s: %s",
                               decode_errors, input_path, exc)
            while pending:
                frame = pending.popleft()
                if first_frame:
                    if frame.time is not None:
                        start_offset_ms = round((frame.time - timeline_start) * 1000)
                    first_frame = False
                if on_progress is not None and frame.time is not None:
                    on_progress(frame.time - timeline_start, total_s)
                for out_packet in stream_out.encode(frame):
                    container_out.mux(out_packet)
                    packets_written += 1
        # flush encoder
        for out_packet in stream_out.encode(None):
            container_out.mux(out_packet)
            packets_written += 1
    finally:
        container_in.close()
        container_out.close()

    if not packets_written:
        raise ValueError("No audio to convert: the file holds none that can be decoded.")
    return str(output_path), start_offset_ms
