import threading
from pathlib import Path
from typing import Dict

_MAP_LOCK = threading.Lock()
_SAFE_TO_ORIGINAL: Dict[str, str] = {}
MAX_RECORDS = 2048


def _normalize_path(path_or_uri: str) -> str:
    raw = path_or_uri.strip()
    if raw.startswith('file://'):
        raw = raw[len('file://'):]
    return str(Path(raw).expanduser().resolve())


def register_safe_image(safe_path: str, original_path: str) -> None:
    safe_abs = _normalize_path(safe_path)
    original_abs = _normalize_path(original_path)
    with _MAP_LOCK:
        _SAFE_TO_ORIGINAL[safe_abs] = original_abs
        if len(_SAFE_TO_ORIGINAL) <= MAX_RECORDS:
            return
        overflow = len(_SAFE_TO_ORIGINAL) - MAX_RECORDS
        for key in list(_SAFE_TO_ORIGINAL.keys())[:overflow]:
            del _SAFE_TO_ORIGINAL[key]


def resolve_original_image(path_or_uri: str) -> str:
    safe_abs = _normalize_path(path_or_uri)
    with _MAP_LOCK:
        return _SAFE_TO_ORIGINAL.get(safe_abs, safe_abs)
