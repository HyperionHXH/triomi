"""Offline behavior checks; these are not claimed as live iOS acceptance."""
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

from dev_fixture_server import png
import run_ios_copy_acceptance as copy
import run_ios_visual_tour as tour

DEVICE = '12345678-1234-1234-1234-123456789ABC'


class CopyBoundaryTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.session = copy.CopySession(DEVICE, Path(temp.name) / 'evidence')
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), copy.CopyCaptureHandler)
        self.server.session = self.session
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close)

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def request(self, method, path, payload=None):
        body = json.dumps(payload).encode() if payload is not None else None
        connection = HTTPConnection('127.0.0.1', self.server.server_port, timeout=5)
        try:
            connection.request(method, path, body, {'Content-Type': 'application/json'})
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def test_no_fixture_or_account_endpoint_can_be_served(self):
        with patch.object(tour.subprocess, 'run') as simctl:
            for method in ('GET', 'POST', 'PUT', 'DELETE', 'PATCH'):
                for path in ('/api/v3/login', '/img/page/1', '/__tour/manga.png', '/comic/yiquanchaoren'):
                    with self.subTest(method=method, path=path):
                        self.assertEqual(self.request(method, path)[0], 405)
            simctl.assert_not_called()

    def test_native_capture_uses_explicit_device_and_records_rule_hash(self):
        calls = []
        def screenshot(command, **kwargs):
            calls.append(command)
            Path(command[-1]).write_bytes(png(120, 240, (len(calls), 50, 80)))
            return subprocess.CompletedProcess(command, 0, '', '')
        with patch.object(tour.subprocess, 'run', side_effect=screenshot):
            for name in copy.CAPTURES:
                status, body = self.request('POST', '/__tour/capture',
                                            {'name': name, 'route': '/reader', 'description': name})
                self.assertEqual(status, 200, body)
        self.session.validate_captures()
        self.assertEqual(len(calls), len(copy.CAPTURES))
        self.assertTrue(all(command[3] == DEVICE for command in calls))
        self.assertEqual(self.session.manifest['rule']['sha256'],
                         copy.sha256(copy.ROOT / 'assets/rules/copymanga-js.json'))
        self.assertEqual(self.session.manifest['expected_captures'], list(copy.CAPTURES))

    def test_missing_capture_and_path_traversal_fail_closed(self):
        with self.assertRaisesRegex(ValueError, 'Missing required'):
            self.session.validate_captures()
        with patch.object(tour.subprocess, 'run') as simctl:
            for name in ('../01_copy_search.png', '01_home_shelf.png'):
                self.assertEqual(self.request('POST', '/__tour/capture', {'name': name})[0], 400)
            simctl.assert_not_called()
        self.assertTrue(self.session.manifest['errors'])

    def test_existing_evidence_is_never_overwritten(self):
        with self.assertRaisesRegex(ValueError, 'must be empty'):
            copy.CopySession(DEVICE, self.session.output)


if __name__ == '__main__':
    unittest.main()
