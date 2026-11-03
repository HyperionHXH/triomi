"""Local host boundary tests, not actual iOS evidence."""
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

from run_ios_copy_acceptance import CopyCaptureHandler
from run_ios_reader_ports import ReaderPortSession, CAPTURES, validate_metadata_reports
from dev_fixture_server import png


class ReaderPortBoundaryTests(unittest.TestCase):
    def metadata_reports(self):
        return [
            {'source': source, 'status': 'blocked_account' if source == 'picacomic'
             else 'metadata_passed', 'requests': [], 'readingValidated': False,
             'iosValidated': False}
            for source in ('picacomic', 'wnacg', 'jmcomic', 'ehentai')
        ]

    def test_metadata_guard_is_not_an_account_or_reading_pass(self):
        validate_metadata_reports(self.metadata_reports())

    def test_failed_metadata_cannot_pass_with_a_zero_flutter_exit(self):
        reports = self.metadata_reports()
        reports[-1]['status'] = 'failed'
        with self.assertRaisesRegex(ValueError, 'status'):
            validate_metadata_reports(reports)

    def test_metadata_rejects_missing_duplicate_and_unknown_sources(self):
        reports = self.metadata_reports()
        for altered in (reports[:-1], reports + [reports[0]],
                        reports[:-1] + [dict(reports[-1], source='unknown')]):
            with self.subTest(sources=[r['source'] for r in altered]):
                with self.assertRaisesRegex(ValueError, 'source set'):
                    validate_metadata_reports(altered)

    def test_anonymous_account_guard_cannot_make_a_network_request(self):
        reports = self.metadata_reports()
        reports[0]['requests'] = [{'host': 'example.invalid', 'method': 'GET'}]
        with self.assertRaisesRegex(ValueError, 'account guard'):
            validate_metadata_reports(reports)

    def test_metadata_cannot_claim_image_or_ios_reading_acceptance(self):
        for field in ('readingValidated', 'iosValidated'):
            reports = self.metadata_reports()
            reports[-1][field] = True
            with self.subTest(field=field):
                with self.assertRaisesRegex(ValueError, 'reading'):
                    validate_metadata_reports(reports)

    def test_account_workflow_draft_is_disabled_and_has_no_secret_bindings(self):
        workflow = (Path(__file__).resolve().parents[1] /
                    '.github/workflows/build-ios.yml').read_text(encoding='utf-8')
        self.assertNotIn('inputs.picacomic_account', workflow)
        # The published workflow has no account job. An optional local draft
        # may remain only if hard-disabled and free of credential bindings.
        if '\n  picacomic-account:\n' not in workflow:
            return
        draft = workflow.split('\n  picacomic-account:\n', 1)[1].split('\n  publish:', 1)[0]
        self.assertIn('    if: ${{ false }}\n', draft)
        self.assertNotIn('secrets.', draft)
        self.assertNotIn('PICACOMIC_ACCOUNT:', draft)
        self.assertNotIn('PICACOMIC_PASSWORD:', draft)

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
