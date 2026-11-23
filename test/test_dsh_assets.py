"""Exercise DSH attachment backup with isolated synthetic homes."""
import base64
import hashlib
import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest


module_path = Path(__file__).resolve().parents[1] / 'agent-dash-dsh-assets.py'
spec = importlib.util.spec_from_file_location('dsh_assets', module_path)
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


class DshAssetTest(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.source = Path(temp.name) / 'source'
        self.target = Path(temp.name) / 'target'
        self.source.mkdir()
        self.target.mkdir()
        self.data = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jB1sAAAAASUVORK5CYII=')
        self.digest = hashlib.sha256(self.data).hexdigest()
        self.blobs = {self.digest: self.data}
        ref = {'attachmentId': 'sha256:' + self.digest, 'bytes': len(self.data)}
        self.file = dict(ref, name='report.png')
        blocks = [{'type': 'image', 'attachment': dict(ref, mediaType='image/png', width=1, height=1)},
                  {'type': 'file', 'attachment': self.file}]
        self.events = [{'type': 'user/message', 'data': {'role': 'user', 'content': blocks}}]
        prefix = Path('attachments/v1')
        self.image_path = prefix / 'objects' / self.digest[:2] / self.digest
        self.file_path = prefix / 'files' / self.digest[:2] / self.digest / 'report.png'
        for path in (self.image_path, self.file_path):
            path = self.source / path
            path.parent.mkdir(parents=True)
            path.write_bytes(self.data)

    def test_cross_home_and_idempotent_install(self):
        (self.source / 'credentials').write_bytes(b'unrelated')
        (self.source / self.image_path.parent / ('a' * 64)).write_bytes(b'unrelated')
        selected = assets.collect(self.source, self.events)
        self.assertEqual(selected, self.blobs)
        for _ in range(2):
            assets.install(self.target, selected, self.events)
            for path in (self.image_path, self.file_path):
                self.assertEqual((self.target / path).read_bytes(), self.data)
        self.assertEqual(assets.collect(self.target, self.events), selected)

    def test_corrupt_missing_extra_and_length(self):
        for invalid in ({}, {self.digest: b'corrupt'}, dict(self.blobs, extra=b'')):
            with self.subTest(keys=list(invalid)), self.assertRaises(ValueError):
                assets.verify_coverage(self.events, invalid)
        self.file['bytes'] += 1
        with self.assertRaises(ValueError):
            assets.collect(self.source, self.events)
        self.file['bytes'] -= 1
        (self.source / self.file_path).write_bytes(b'damaged')
        with self.assertRaises(ValueError):
            assets.collect(self.source, self.events)
        with self.assertRaises(ValueError):
            assets.install(self.source, self.blobs, self.events)
        self.assertEqual((self.source / self.file_path).read_bytes(), b'damaged')

    def test_subset_skips_unselected_assets(self):
        archive = dict(self.blobs, extra=b'other session')
        self.assertEqual(assets.subset(self.events, archive), self.blobs)
        self.assertEqual(assets.subset([], archive), {})
        with self.assertRaisesRegex(ValueError, 'missing selected references'):
            assets.subset(self.events, {})

    def test_collect_checks_declared_and_stored_size_before_reading(self):
        limit = 256 * 1024 * 1024
        events = [{'type': 'file', 'attachment': self.file}]
        self.file['bytes'] = limit + 1
        with self.assertRaisesRegex(ValueError, '256 MiB'):
            assets.collect(self.source / 'missing-home', events)
        self.file['bytes'] = len(self.data)
        # A sparse file exercises the size check without storing a large fixture.
        with (self.source / self.file_path).open('r+b') as stream:
            stream.truncate(limit + 1)
        with self.assertRaisesRegex(ValueError, 'length does not match'):
            assets.collect(self.source, events)

    def test_reject_unsafe_paths(self):
        for name in ('../credentials', '/tmp/file', 'folder\\credentials'):
            self.file['name'] = name
            with self.subTest(name=name), self.assertRaises(ValueError):
                assets.collect(self.source, self.events)
        self.file['name'] = 'report.png'
        (self.target / 'attachments').symlink_to(self.source / 'attachments')
        with self.assertRaises(OSError):
            assets.collect(self.target, self.events)
        with self.assertRaises(OSError):
            assets.install(self.target, self.blobs, self.events)
        alias = self.source / self.file_path
        alias.unlink()
        alias.symlink_to(self.source / self.image_path)
        with self.assertRaises(OSError):
            assets.collect(self.source, self.events)
