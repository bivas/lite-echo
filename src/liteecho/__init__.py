"""LiteEcho: local transcription engine."""
from importlib import metadata as _metadata

try:
    __version__ = _metadata.version("liteecho")
except _metadata.PackageNotFoundError:  # running from a source tree without an install
    __version__ = "0.5.2"
