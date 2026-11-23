"""Copy only DSH content-block attachment references, never arbitrary paths."""
import hashlib
import os
import re
import stat
from pathlib import Path

_ID = re.compile(r"sha256:([a-f0-9]{64})\Z")
_DEVICE = re.compile(r"^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)", re.I)
_MAX_COLLECT_BYTES = 256 * 1024 * 1024


def _refs(events):
    refs = []
    def walk(value):
        if isinstance(value, list):
            for item in value:
                walk(item)
        elif isinstance(value, dict):
            if value.get('type') in ('image', 'file') and 'attachment' in value:
                ref = value['attachment']
                if not isinstance(ref, dict):
                    raise ValueError('invalid attachment reference')
                match = _ID.fullmatch(ref.get('attachmentId', '') if isinstance(ref.get('attachmentId'), str) else '')
                size = ref.get('bytes')
                if not match or type(size) is not int or size < 0:
                    raise ValueError('invalid attachment id or length')
                kind = value['type']
                name = ref.get('name')
                if kind == 'file':
                    if (not isinstance(name, str) or not name or name in ('.', '..') or
                        len(name.encode('utf-8')) > 255 or name != name.strip().rstrip('. ') or
                        re.search(r'[\x00-\x1f\x7f/\\<>:"|?*]', name) or _DEVICE.match(name)):
                        raise ValueError('invalid attachment filename')
                refs.append((kind, match.group(1), size, name))
            for item in value.values():
                walk(item)
    walk(events)
    return refs


def _parts(kind, digest, name):
    if kind == 'image':
        return ('attachments', 'v1', 'objects', digest[:2], digest)
    return ('attachments', 'v1', 'files', digest[:2], digest, name)


def _directory(home, parts, create=False):
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    fd = os.open(home, flags)
    try:
        for part in parts:
            if create:
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            child = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def _read(home, parts, size):
    directory = _directory(home, parts[:-1])
    try:
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                raise ValueError('attachment is not a regular file')
            if info.st_size != size:
                raise ValueError('attachment length does not match its reference')
            with os.fdopen(fd, 'rb') as stream:
                fd = -1
                data = stream.read(size)
                if stream.read(1):
                    raise ValueError('attachment grew during read')
                return data
        finally:
            if fd != -1:
                os.close(fd)
    finally:
        os.close(directory)


def _check(digest, data, size=None):
    if not isinstance(data, bytes) or hashlib.sha256(data).hexdigest() != digest or (size is not None and len(data) != size):
        raise ValueError('attachment integrity verification failed')


def collect(home: Path, events: list) -> dict:
    assets = {}
    for kind, digest, size, name in _refs(events):
        if size > _MAX_COLLECT_BYTES:
            raise ValueError('attachment exceeds the 256 MiB backup limit')
        data = _read(home, _parts(kind, digest, name), size)
        _check(digest, data, size)
        assets[digest] = data
    return assets


def subset(events: list, assets: dict) -> dict:
    """Select the blobs required by events from a previously verified archive."""
    needed = {digest for _, digest, _, _ in _refs(events)}
    if not needed.issubset(assets):
        raise ValueError('attachment archive is missing selected references')
    return {digest: assets[digest] for digest in needed}


def verify_coverage(events: list, assets: dict) -> None:
    refs = _refs(events)
    needed = {digest for _, digest, _, _ in refs}
    if set(assets) != needed:
        raise ValueError('attachment archive does not match selected references')
    for _, digest, size, _ in refs:
        _check(digest, assets[digest], size)


def install(home: Path, assets: dict, events: list) -> None:
    verify_coverage(events, assets)
    for kind, digest, _, name in _refs(events):
        parts = _parts(kind, digest, name)
        directory = _directory(home, parts[:-1], create=True)
        temporary = None
        try:
            # Stage on the same filesystem, then atomically publish without replacing.
            for _ in range(100):
                candidate = '.agent-dash-' + os.urandom(16).hex()
                try:
                    fd = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
                    temporary = candidate
                    break
                except FileExistsError:
                    continue
            else:
                raise FileExistsError('unable to allocate attachment staging file')
            with os.fdopen(fd, 'wb') as stream:
                stream.write(assets[digest])
                stream.flush()
                os.fsync(stream.fileno())
                os.fchmod(stream.fileno(), 0o400)
            try:
                os.link(temporary, parts[-1], src_dir_fd=directory, dst_dir_fd=directory, follow_symlinks=False)
            except FileExistsError:
                _check(digest, _read(home, parts, len(assets[digest])))
            os.fsync(directory)
        finally:
            if temporary is not None:
                try:
                    os.unlink(temporary, dir_fd=directory)
                except FileNotFoundError:
                    pass
            os.close(directory)
