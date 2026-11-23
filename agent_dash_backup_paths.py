"""Compare archived Windows source paths independently of the import host."""
import os
from pathlib import PureWindowsPath


def absolute_source(path):
    return isinstance(path, str) and '\x00' not in path and (
        os.path.isabs(path) or PureWindowsPath(path).is_absolute())


def codex_destination(path, mappings):
    if isinstance(path, str):
        for old, new in sorted(mappings, key=lambda pair: len(pair[0]), reverse=True):
            if path == old or (path.startswith('/') and path.rstrip('/') == old.rstrip('/')):
                return new
            target = windows_destination(path, old, new)
            if target is not None:
                return target
    return path


def windows_destination(path, old, new):
    """Return the local destination for a Windows prefix, or None when unmatched."""
    source = PureWindowsPath(old)
    if not source.is_absolute():
        return None
    try:
        relative = PureWindowsPath(path).relative_to(source)
    except ValueError:
        return None
    if '..' in relative.parts:
        return None
    return os.path.join(new, *relative.parts)
