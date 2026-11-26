#!/usr/bin/env python3
"""Read embedded user images from an Antigravity v1 trajectory database."""
import base64
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import sys


def varint(data, pos):
    value = 0
    for shift in range(0, 70, 7):
        if pos >= len(data):
            raise ValueError('truncated protobuf varint')
        byte = data[pos]
        pos += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, pos
    raise ValueError('invalid protobuf varint')


def fields(data):
    pos = 0
    while pos < len(data):
        tag, pos = varint(data, pos)
        number, wire = divmod(tag, 8)
        if not number:
            raise ValueError('invalid protobuf tag')
        if wire == 0:
            _, pos = varint(data, pos)
            continue
        if wire == 2:
            size, pos = varint(data, pos)
        elif wire in (1, 5):
            size = 8 if wire == 1 else 4
        else:
            raise ValueError('unsupported protobuf wire type')
        end = pos + size
        if end > len(data):
            raise ValueError('truncated protobuf field')
        if wire == 2:
            yield number, data[pos:end]
        pos = end


def prompts(path, limit):
    with closing(sqlite3.connect(path.absolute().as_uri() + '?mode=ro', uri=True)) as db:
        db.execute('PRAGMA trusted_schema=OFF')
        if db.execute('PRAGMA user_version').fetchone() != (1,):
            return []
        result = []
        for payload, encoding in db.execute(
                'SELECT step_payload, step_format FROM steps WHERE step_type=14 ORDER BY idx'):
            if encoding != 0 or payload is None:
                return []
            # TrajectoryStep.user_input = 19, UserInput.query = 2, images = 9.
            prompt = dict(fields(payload)).get(19)
            if prompt is None:
                return []
            text = ''
            images = []
            for field, data in fields(prompt):
                if field == 2:
                    text = data.decode('utf-8')
                elif field == 9:
                    # Embedded image bytes are field 2. Emacs validates the MIME signature.
                    raw = dict(fields(data)).get(2, b'')
                    if 0 < len(raw) <= limit:
                        images.append(base64.b64encode(raw).decode('ascii'))
            result.append({'text': text, 'images': images})
        return result


if __name__ == '__main__':
    try:
        print(json.dumps(prompts(Path(sys.argv[1]), int(sys.argv[2]))))
    except (OSError, ValueError, sqlite3.Error) as error:
        sys.exit(str(error))
