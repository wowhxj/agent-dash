#!/usr/bin/env python3
"""Start Antigravity ACP with the active Magpie gateway when configured."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
from threading import Thread


def gateway(magpie):
    try:
        output = subprocess.check_output([magpie, 'agy', 'env'], stderr=subprocess.DEVNULL,
                                         text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    settings = dict(line.split('=', 1) for line in output.splitlines() if '=' in line)
    if (settings.get('model', '').startswith('magpie/') and settings.get('GEMINI_API_KEY')
            and settings.get('GOOGLE_GEMINI_BASE_URL')):
        return settings['GEMINI_API_KEY']
    return None


def response(child, request_id, forward):
    for line in iter(child.stdout.readline, b''):
        try:
            record = json.loads(line)
        except ValueError:
            record = {}
        if record.get('id') == request_id and 'method' not in record:
            return line, record
        if forward:
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
    raise EOFError()


def proxy(magpie, args, key):
    with subprocess.Popen([magpie, 'agy', 'run', *args], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE) as child:
        def stop(signum, _frame):
            if child.poll() is None:
                child.send_signal(signum)
            raise SystemExit(128 + signum)

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        try:
            source = sys.stdin.buffer.raw
            first = source.readline()
            if not first:
                return 0
            initialize = json.loads(first)
            child.stdin.write(first)
            child.stdin.flush()
            reply, result = response(child, initialize['id'], True)
            if 'result' in result:
                request = {'jsonrpc': '2.0', 'id': 'agent-dash-magpie-auth',
                           'method': 'authenticate', 'params': {'methodId': 'gemini-api-key',
                                                               '_meta': {'apiKey': key}}}
                child.stdin.write(json.dumps(request).encode() + b'\n')
                child.stdin.flush()
                _, auth = response(child, request['id'], False)
                if 'error' in auth:
                    print('Antigravity ACP rejected Magpie authentication', file=sys.stderr)
            sys.stdout.buffer.write(reply)
            sys.stdout.buffer.flush()

            def send():
                try:
                    while chunk := source.read(65536):
                        child.stdin.write(chunk)
                        child.stdin.flush()
                except (OSError, ValueError):
                    pass
                finally:
                    child.stdin.close()

            Thread(target=send, daemon=True).start()
            while chunk := child.stdout.read1(65536):
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
            return child.wait()
        except (EOFError, OSError, ValueError, KeyError):
            return 1
        finally:
            if child.poll() is None:
                child.terminate()


def main():
    magpie, agy, *args = sys.argv[1:]
    key = gateway(magpie)
    if key:
        return proxy(magpie, args, key)
    os.execv(agy, [agy, *args])


if __name__ == '__main__':
    sys.exit(main())
