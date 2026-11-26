"""Per-language whisper prompts (``assets/prompts/prompts.yml``).

The file is a mapping of quoted language code to a prompt string, e.g. ``"no": "..."`` (quoted
because unquoted ``no`` is a YAML boolean). The prompt is handed to faster-whisper as
``hotwords``; a language without an entry gets none.
"""
from __future__ import annotations

from pathlib import Path

PROMPTS_FILE = "prompts.yml"


def load(prompts_dir: str | Path) -> dict[str, str]:
    """All prompts in ``prompts_dir/prompts.yml``; {} if the file is missing or unreadable.

    Entries whose key is not a string (an unquoted ``no`` / ``yes`` read as a boolean) or whose
    value is not a non-empty string are ignored.
    """
    import yaml
    try:
        with open(Path(prompts_dir) / PROMPTS_FILE, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except (OSError, yaml.YAMLError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {k: v for k, v in data.items()
            if isinstance(k, str) and isinstance(v, str) and v.strip()}


def for_language(prompts_dir: str | Path, code: str | None) -> str | None:
    """The prompt for ``code``, or None."""
    if not code:
        return None
    return load(prompts_dir).get(code)
