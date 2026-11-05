import contextlib
import io
import json
import pathlib
import ssl
import tempfile
import unittest
import urllib.error
from unittest import mock

import pica_auth_rejection_probe as probe


class Response:
    def __init__(self, status, body):
        self.code, self.body, self.read_limits = status, body, []

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self, limit):
        self.read_limits.append(limit)
        return self.body[:limit]


class Client:
    def __init__(self, responses):
        self.responses, self.calls = list(responses), []

    def open(self, request, timeout):
        self.calls.append((request, timeout))
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


class ProbeTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(probe, "request_deadline", contextlib.nullcontext)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_exactly_two_reserved_account_posts_same_body_fresh_signatures(self):
        responses = [Response(400, b'{"code":400,"message":"Invalid email or password"}'),
                     Response(400, b'{"code":400,"message":"Invalid signature"}')]
        client = Client(responses)
        with mock.patch.object(probe.secrets, "token_urlsafe", return_value="synthetic-password") as password, \
                mock.patch.object(probe.secrets, "choice", side_effect=["A"] * 32 + ["B"] * 32), \
                mock.patch.object(probe.time, "time", side_effect=[1700000000, 1700000001]):
            result = probe.run(client, "fixture-api", "fixture-key")
        password.assert_called_once_with(24)
        self.assertEqual(len(client.calls), 2)
        self.assertEqual(result["realAccountAcceptance"], "notTested")
        self.assertEqual(result["runStatus"], "httpResponsesRecorded")
        first, second = [call[0] for call in client.calls]
        self.assertEqual(first.data, second.data)
        self.assertEqual(json.loads(first.data), {
            "email": "fixture-reader@example.invalid", "password": "fixture-synthetic-password"})
        self.assertEqual(first.get_header("Nonce"), "A" * 32)
        self.assertEqual(second.get_header("Nonce"), "B" * 32)
        self.assertEqual(first.get_header("Time"), "1700000000")
        self.assertEqual(second.get_header("Time"), "1700000001")
        self.assertNotEqual(first.get_header("Signature"), second.get_header("Signature"))
        self.assertEqual(first.get_header("Signature"),
                         "48a9822c5f2d69d07f9c6d26e24f714c9d753f391502d7b7d1f27dcca232039f")
        for index, (request, timeout) in enumerate(client.calls):
            self.assertEqual(request.full_url, "https://picaapi.picacomic.com/auth/sign-in")
            self.assertEqual(request.get_method(), "POST")
            self.assertEqual(timeout, 20)
            self.assertEqual(request.get_header("App-channel"), "1")
            self.assertEqual(request.get_header("Content-type"), "application/json; charset=UTF-8")
            self.assertEqual(request.get_header("Authorization"), None if index == 0 else "")
            self.assertFalse(request.has_header("Cookie"))
            self.assertEqual(responses[index].read_limits, [8193])
        self.assertNotIn("fixture-", json.dumps(result))

    def test_http200_always_fails_and_does_not_read_session_body(self):
        response = Response(200, b'{"code":200,"data":{"token":"fixture-private-token"}}')
        client = Client([response, Response(400, b'{"code":400}')])
        result = probe.run(client, "fixture-api", "fixture-signing")
        self.assertEqual(len(client.calls), 2)
        self.assertEqual(result["runStatus"], "failed")
        self.assertEqual(response.read_limits, [])
        self.assertEqual(result["results"][0], {
            "authorizationMode": "omitted", "requestStatus": "unexpectedSuccess",
            "httpStatus": 200, "responseClass": "unexpectedSuccess"})
        self.assertNotIn("fixture-", json.dumps(result))
        self.assertNotIn("token", json.dumps(result))

    def test_transport_failure_is_failure_without_retry_or_raw_error(self):
        client = Client([urllib.error.URLError("fixture-password fixture-token"),
                         Response(401, b'{"code":401,"message":"Unauthorized"}')])
        result = probe.run(client, "fixture-api", "fixture-signing")
        self.assertEqual(len(client.calls), 2)
        self.assertEqual(result["runStatus"], "failed")
        self.assertEqual(result["results"][0]["errorType"], "URLError")
        self.assertNotIn("fixture-", json.dumps(result))

    def test_all_other_2xx_are_also_unexpected_success_without_body_read(self):
        for status in (201, 204, 299):
            response = Response(status, b'fixture-private-token')
            result = probe.probe(Client([response]),
                                 probe.request_for("fixture-api", "fixture-key", b'{}', False), False)
            self.assertEqual(result["requestStatus"], "unexpectedSuccess")
            self.assertEqual(response.read_limits, [])

    def test_parser_never_echoes_remote_text(self):
        fixtures = [
            (b'{"code":400,"message":"fixture-token","detail":"fixture-password"}', "jsonAPI", "unknown"),
            (b'{"code":400,"message":"Invalid email or password"}', "jsonAPI", "invalidCredentials"),
            (b'{"message":"fixture-token"}', "otherJSON", "unknown"),
            (b'["fixture-password"]', "otherJSON", "unavailable"),
            (b'<html>fixture-password</html>', "nonJSON", "unavailable"),
            (b'\xff', "nonJSON", "unavailable"),
            (b'x' * 8193, "oversize", "unavailable"),
        ]
        for body, body_class, message_class in fixtures:
            with self.subTest(body_class=body_class):
                result = probe.classify_body(body)
                self.assertEqual(result, {"bodyClass": body_class, "messageClass": message_class})
                self.assertNotIn("fixture-", json.dumps(result))

    def test_redirect_is_not_followed_and_never_replays_credentials(self):
        handler = probe.NoRedirect()
        request = probe.request_for("fixture-api", "fixture-key", b"fixture-password", False)
        for status in (301, 302, 303, 307, 308):
            self.assertIsNone(handler.redirect_request(request, None, status,
                                                      "fixture-secret", {}, probe.ENDPOINT))
        error = urllib.error.HTTPError(probe.ENDPOINT, 302, "fixture-secret",
                                       {"Location": "https://untrusted.invalid"}, io.BytesIO(b'fixture-secret'))
        client = Client([error])
        result = probe.probe(client, request, False)
        self.assertEqual(len(client.calls), 1)
        self.assertEqual(result["httpStatus"], 302)
        self.assertEqual(result["responseClass"], "redirectRejected")
        self.assertNotIn("fixture-", json.dumps(result))

    def test_tls_verification_and_no_ambient_proxy(self):
        with mock.patch.object(probe.urllib.request, "build_opener") as build:
            probe.opener()
        handlers = build.call_args.args
        self.assertEqual(handlers[0].proxies, {})
        self.assertEqual(handlers[1]._context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(handlers[1]._context.check_hostname)
        self.assertIsInstance(handlers[2], probe.NoRedirect)

    def test_protocol_extraction_rejects_wrong_origin(self):
        source = "const picaApi = 'https://picaapi.picacomic.com';\nconst _apiKey = 'fixture-api';\nconst _signingKey = r'fixture-key';"
        self.assertEqual(probe.protocol_constants(source), ("fixture-api", "fixture-key"))
        with self.assertRaises(ValueError):
            probe.protocol_constants(source.replace("https://picaapi.picacomic.com", "https://elsewhere.invalid"))

    def test_main_failure_artifact_and_stdout_are_safe(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "result.json"
            with mock.patch.object(probe, "SOURCE") as source, mock.patch.object(probe, "OUTPUT", output):
                source.read_text.side_effect = ValueError("fixture-password fixture-token")
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    self.assertEqual(probe.main(), 1)
            self.assertNotIn("fixture-", stdout.getvalue())
            self.assertEqual(json.loads(output.read_text())["runStatus"], "failed")


class DeadlineTests(unittest.TestCase):
    def test_total_posix_deadline_and_cleanup_on_timeout(self):
        with mock.patch.object(probe.signal, "SIGALRM", 14, create=True), \
                mock.patch.object(probe.signal, "ITIMER_REAL", 0, create=True), \
                mock.patch.object(probe.signal, "signal", create=True) as handler, \
                mock.patch.object(probe.signal, "setitimer", create=True) as timer:
            with self.assertRaises(TimeoutError):
                with probe.request_deadline():
                    installed = handler.call_args_list[0].args[1]
                    installed(14, None)
            self.assertEqual(timer.call_args_list[0].args, (0, 20))
            self.assertEqual(timer.call_args_list[-1].args, (0, 0))
            self.assertEqual(handler.call_args_list[-1].args, (14, handler.return_value))


if __name__ == "__main__":
    unittest.main()
