"""Local host boundary tests, not actual iOS evidence."""
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

from run_ios_copy_acceptance import CopyCaptureHandler
from run_ios_reader_ports import ReaderPortSession, CAPTURES
from dev_fixture_server import png


class ReaderPortBoundaryTests(unittest.TestCase):
    def test_source_snapshot_is_four_exact_rules_and_no_live_image_claim(self):
        with tempfile.TemporaryDirectory() as temp:
            session = ReaderPortSession('12345678-1234-1234-1234-123456789ABC', Path(temp))
            self.assertEqual({r['id'] for r in session.manifest['rules']},
                             {'picacomic', 'wnacg', 'jmcomic', 'ehentai'})
            self.assertTrue(all(len(r['sha256']) == 64 for r in session.manifest['rules']))
            self.assertEqual(tuple(session.manifest['expected_captures']), CAPTURES)
            self.assertIn('Synthetic', session.manifest['source_boundaries']['content'])
            with self.assertRaisesRegex(ValueError, 'empty'):
                ReaderPortSession(session.device, Path(temp))

    def test_capture_server_never_serves_images_or_accepts_remote_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            session = ReaderPortSession('12345678-1234-1234-1234-123456789ABC', Path(temp))
            server = ThreadingHTTPServer(('127.0.0.1', 0), CopyCaptureHandler)
            server.session = session
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                with patch('run_ios_visual_tour.subprocess.run') as process:
                    for method in ('GET', 'POST', 'PUT', 'DELETE', 'PATCH'):
                        connection = HTTPConnection('127.0.0.1', server.server_port, timeout=5)
                        connection.request(method, '/auth/sign-in', b'{}')
                        response = connection.getresponse()
                        self.assertEqual(response.status, 405)
                        response.read()
                        connection.close()
                    process.assert_not_called()
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)

    def test_native_capture_keeps_the_explicit_device(self):
        with tempfile.TemporaryDirectory() as temp:
            session = ReaderPortSession('12345678-1234-1234-1234-123456789ABC', Path(temp))
            def capture(command, **kwargs):
                self.assertEqual(command[:5], ['xcrun', 'simctl', 'io', session.device, 'screenshot'])
                Path(command[-1]).write_bytes(png(12, 16, (25, 100, 85)))
            with patch('run_ios_visual_tour.subprocess.run', side_effect=capture):
                result = session.capture({'name': CAPTURES[0], 'description': 'Synthetic fixture'})
            self.assertEqual(result['sequence'], 1)
            self.assertEqual((result['width'], result['height']), (12, 16))
            with self.assertRaisesRegex(ValueError, 'Missing'):
                session.validate_captures()


if __name__ == '__main__':
    unittest.main()
