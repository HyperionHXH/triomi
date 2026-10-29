"""Offline protocol tests for the real iOS tour's loopback capture boundary.

Only simctl is replaced: requests traverse the real HTTP server, PNG validation,
ordered manifest persistence and required-frame validation.
"""
from http.client import HTTPConnection
import hashlib
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

from dev_fixture_server import png
import run_ios_visual_tour as tour


DEVICE = '12345678-1234-1234-1234-123456789ABC'


class SimulatorValidationTests(unittest.TestCase):
    def test_validates_only_the_explicit_running_simulator(self):
        device = '12345678-1234-1234-1234-123456789ABC'
        response = subprocess.CompletedProcess(
            ['xcrun', 'simctl', 'getenv', device, 'SIMULATOR_UDID'],
            0,
            f'{device}\n',
            '',
        )
        with patch.object(tour.subprocess, 'run', return_value=response) as simctl:
            self.assertEqual(tour.validate_device(device)['udid'], device)
        simctl.assert_called_once_with(
            ['xcrun', 'simctl', 'getenv', device, 'SIMULATOR_UDID'],
            capture_output=True,
            text=True,
            check=True,
            timeout=60,
        )

    def test_rejects_non_uuid_or_mismatched_simulator_without_global_enumeration(self):
        with patch.object(tour.subprocess, 'run') as simctl:
            with self.assertRaisesRegex(ValueError, 'explicit iOS Simulator UDID'):
                tour.validate_device('booted')
            response = subprocess.CompletedProcess([], 0, '87654321-1234-1234-1234-123456789ABC\n', '')
            simctl.return_value = response
            with self.assertRaisesRegex(ValueError, 'not running with the requested UDID'):
                tour.validate_device('12345678-1234-1234-1234-123456789ABC')
        self.assertEqual(simctl.call_count, 1)


class CaptureProtocolTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name) / 'tour'
        self.session = tour.TourSession(DEVICE, self.output)
        self.server = tour.TourServer(self.session)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)

    def stop_server(self):
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

    def capture(self, name, **metadata):
        return self.request('POST', '/__tour/capture', {'name': name, **metadata})

    def screenshot(self, command, **kwargs):
        self.frame += 1
        Path(command[-1]).write_bytes(png(120, 240, (self.frame, 50, 80)))
        return subprocess.CompletedProcess(command, 0, '', '')

    def test_path_traversal_and_unknown_names_never_invoke_capture(self):
        invalid = (
            '../01_home_shelf.png', '/tmp/01_home_shelf.png',
            r'..\01_home_shelf.png', 'screenshots/01_home_shelf.png',
            '%2e%2e%2f01_home_shelf.png', '01_home_shelf.png\x00',
            '01_unagreed_scene.png',
        )
        with patch.object(tour.subprocess, 'run') as simctl:
            for name in invalid:
                with self.subTest(name=name):
                    status, body = self.capture(name)
                    self.assertEqual(status, 400, body)
            simctl.assert_not_called()
        self.assertEqual(self.session.manifest['captures'], [])
        self.assertEqual(list(self.session.screenshots.iterdir()), [])

    def test_failed_simulator_screenshot_returns_non_200_and_records_failure(self):
        error = subprocess.CalledProcessError(1, ['simctl'], stderr='simulator unavailable')
        with patch.object(tour.subprocess, 'run', side_effect=error):
            status, body = self.capture('01_home_shelf.png')
        self.assertEqual(status, 500)
        self.assertIn('Screenshot failed', json.loads(body)['error'])
        manifest = json.loads((self.output / 'manifest.json').read_text(encoding='utf-8'))
        self.assertEqual(manifest['captures'], [])
        self.assertIn('Screenshot failed', manifest['errors'][0])

    def test_non_png_screenshot_is_not_acknowledged_as_a_capture(self):
        def invalid_screenshot(command, **kwargs):
            Path(command[-1]).write_bytes(b'not a screenshot')
            return subprocess.CompletedProcess(command, 0, '', '')

        with patch.object(tour.subprocess, 'run', side_effect=invalid_screenshot):
            status, body = self.capture('01_home_shelf.png')
        self.assertEqual(status, 500)
        self.assertIn('Invalid PNG', json.loads(body)['error'])
        self.assertEqual(self.session.manifest['captures'], [])

    def test_success_records_real_png_metadata_and_request_order(self):
        self.frame = 0
        with patch.object(tour.subprocess, 'run', side_effect=self.screenshot):
            first, body = self.capture(
                '03_search_explore.png', route='/search', description='Local fixture results',
            )
            second, _ = self.capture('01_home_shelf.png', route='/shelf')
        self.assertEqual((first, second), (200, 200))
        capture = json.loads(body)
        self.assertEqual((capture['width'], capture['height']), (120, 240))
        self.assertEqual(capture['sha256'], tour.sha256(self.session.screenshots / capture['name']))
        manifest = json.loads((self.output / 'manifest.json').read_text(encoding='utf-8'))
        self.assertEqual([item['name'] for item in manifest['captures']],
                         ['03_search_explore.png', '01_home_shelf.png'])
        self.assertEqual([item['sequence'] for item in manifest['captures']], [1, 2])
        self.assertEqual(manifest['captures'][0]['route'], '/search')
        self.assertEqual(manifest['captures'][0]['description'], 'Local fixture results')

    def test_duplicate_name_and_identical_frame_are_rejected(self):
        def same_frame(command, **kwargs):
            Path(command[-1]).write_bytes(png(120, 240, (30, 50, 80)))
            return subprocess.CompletedProcess(command, 0, '', '')

        with patch.object(tour.subprocess, 'run', side_effect=same_frame) as simctl:
            self.assertEqual(self.capture('01_home_shelf.png')[0], 200)
            duplicate, body = self.capture('01_home_shelf.png')
            self.assertEqual(duplicate, 409)
            self.assertIn('Duplicate capture name', json.loads(body)['error'])
            self.assertEqual(simctl.call_count, 1)
            identical, body = self.capture('02_source_rules.png')
            self.assertEqual(identical, 409)
            self.assertIn('Duplicate screenshot frame', json.loads(body)['error'])
        self.assertEqual(len(self.session.manifest['captures']), 1)

    def test_complete_capture_validation_rejects_missing_and_changed_files(self):
        self.frame = 0
        with patch.object(tour.subprocess, 'run', side_effect=self.screenshot):
            for name in tour.EXPECTED_CAPTURES[:-1]:
                self.assertEqual(self.capture(name)[0], 200)
            with self.assertRaisesRegex(ValueError, tour.EXPECTED_CAPTURES[-1]):
                self.session.validate_captures()
            self.assertEqual(self.capture(tour.EXPECTED_CAPTURES[-1])[0], 200)
        self.session.validate_captures()
        target = self.session.screenshots / tour.REQUIRED_CAPTURES[0]
        original = target.read_bytes()
        target.write_bytes(png(120, 240, (200, 150, 100)))
        with self.assertRaisesRegex(ValueError, 'changed after capture'):
            self.session.validate_captures()
        target.write_bytes(original)
        target.unlink()
        with self.assertRaisesRegex(ValueError, 'files do not match'):
            self.session.validate_captures()

    def test_original_seven_alone_do_not_pass_the_expanded_tour(self):
        self.frame = 0
        with patch.object(tour.subprocess, 'run', side_effect=self.screenshot):
            for name in tour.REQUIRED_CAPTURES:
                self.assertEqual(self.capture(name)[0], 200)
        with self.assertRaisesRegex(ValueError, '06_danmaku_gamer_pool.png'):
            self.session.validate_captures()

    def test_independent_pool_capture_names_preserve_order_and_metadata(self):
        self.frame = 0
        names = ('06_danmaku_sources.png', '06_danmaku_bilibili_pool.png',
                 '06_danmaku_animeko_pool.png', '06_danmaku_gamer_pool.png')
        with patch.object(tour.subprocess, 'run', side_effect=self.screenshot):
            for name in names:
                status, body = self.capture(name, route='/player', description='Loopback pool')
                self.assertEqual(status, 200, body)
        self.assertEqual([item['name'] for item in self.session.manifest['captures']], list(names))
        self.assertTrue(all(item['route'] == '/player'
                            for item in self.session.manifest['captures']))

    def test_fixture_account_and_storage_mutations_are_disabled(self):
        for method, path in (
            ('POST', '/api/v2/login'), ('POST', '/api/v2/comment/1'),
            ('PUT', '/dav/backup.zip'), ('MKCOL', '/dav/backup'),
            ('POST', '/lk/login'), ('PATCH', '/tracking/1'),
        ):
            with self.subTest(method=method, path=path):
                self.assertEqual(self.request(method, path, {})[0], 405)
        self.assertEqual(self.server.server_address[0], '127.0.0.1')
        status, body = self.request('GET', '/novelread/tour-1')
        self.assertEqual(status, 200)
        self.assertIn('夹具小说', body.decode('utf-8'))

    def test_compatible_catalog_pins_the_packaged_rule_without_serving_apks(self):
        status, body = self.request('GET', '/__tour/catalog/repo.json')
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)['triomi']['indexUrl'],
                         'https://tour-catalog.invalid/index.json')
        status, body = self.request('GET', '/__tour/catalog/index.json')
        self.assertEqual(status, 200)
        entry = json.loads(body)['sources'][0]
        status, rule = self.request('GET', '/__tour/catalog/rules/xkcd.json')
        self.assertEqual(status, 200)
        self.assertEqual(entry['id'], json.loads(rule)['id'])
        self.assertEqual(entry['version'], json.loads(rule)['version'])
        self.assertEqual(entry['hash'], hashlib.sha256(rule).hexdigest())
        self.assertEqual(self.request('GET', '/__tour/catalog/rules/unknown.apk')[0], 404)


class RecorderFinalizationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name)

    def recorder(self, process):
        recorder = tour.VideoRecorder(DEVICE, self.output)
        recorder.process = process
        recorder.log = (self.output / 'recording.log').open('wb')
        return recorder

    def test_recording_is_closed_by_sigint_and_awaited_before_validation(self):
        process = Mock()
        process.poll.return_value = None

        def finalize(timeout):
            self.assertTrue(process.send_signal.called)
            (self.output / 'ios_ui_tour.mp4').write_bytes(b'finalized by recorder')
            return 0

        process.wait.side_effect = finalize
        recorder = self.recorder(process)
        recorder.stop()
        process.send_signal.assert_called_once_with(signal.SIGINT)
        process.wait.assert_called_once_with(timeout=30)
        process.terminate.assert_not_called()
        process.kill.assert_not_called()
        self.assertTrue(recorder.log.closed)
        self.assertEqual(recorder.path.read_bytes(), b'finalized by recorder')

    def test_unfinalized_recorder_is_a_failure_even_if_child_can_be_terminated(self):
        process = Mock()
        process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired('recordVideo', 30), 0]
        recorder = self.recorder(process)
        with self.assertRaisesRegex(RuntimeError, 'did not finalize after SIGINT'):
            recorder.stop()
        process.terminate.assert_called_once()
        process.kill.assert_not_called()
        self.assertTrue(recorder.log.closed)


if __name__ == '__main__':
    unittest.main()
