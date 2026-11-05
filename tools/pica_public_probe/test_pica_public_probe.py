import contextlib
import io
import json
import pathlib
import ssl
import tempfile
import unittest
import urllib.error
from unittest import mock

import pica_public_probe as probe


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
    def test_only_two_bodyless_official_gets_and_auth_difference(self):
        responses = [Response(401, b'{"code":401,"message":"Unauthorized"}'),
                     Response(400, b'{"code":400,"message":"Invalid signature"}')]
        client = Client(responses)
        result = probe.run(client, "fixture-api", "fixture-signing")
        self.assertEqual(len(client.calls), 2)
        self.assertEqual(result["accountAcceptance"], "notTested")
        self.assertEqual(result["runStatus"], "httpResponsesRecorded")
        for index, (request, timeout) in enumerate(client.calls):
            self.assertEqual(request.full_url, probe.ENDPOINT)
            self.assertEqual(request.get_method(), "GET")
            self.assertIsNone(request.data)
            self.assertEqual(timeout, 20)
            self.assertEqual(request.get_header("App-channel"), "1")
            self.assertEqual(request.get_header("Authorization"), None if index == 0 else "")
            self.assertFalse(request.has_header("Cookie"))
            self.assertEqual(responses[index].read_limits, [8193])

    def test_transport_failure_is_failure_without_retry_or_raw_error(self):
        client = Client([urllib.error.URLError("fixture-password fixture-token"),
                         Response(401, b'{"code":401,"message":"Unauthorized"}')])
        result = probe.run(client, "fixture-api", "fixture-signing")
        self.assertEqual(len(client.calls), 2)
        self.assertEqual(result["runStatus"], "failed")
        self.assertEqual(result["results"][0]["errorType"], "URLError")
        self.assertNotIn("fixture-", json.dumps(result))

    def test_parser_never_echoes_remote_text(self):
        fixtures = [
            (b'{"code":400,"message":"fixture-token","detail":"fixture-password"}', "jsonAPI", "unknown"),
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

    def test_redirect_is_not_followed_even_to_official_origin(self):
        handler = probe.NoRedirect()
        request = probe.request_for("fixture-api", "fixture-key", False)
        for status in (301, 302, 303, 307, 308):
            self.assertIsNone(handler.redirect_request(request, None, status,
                                                      "fixture-secret", {}, probe.ENDPOINT))
        error = urllib.error.HTTPError(probe.ENDPOINT, 302, "fixture-secret",
                                       {"Location": "https://untrusted.invalid"}, io.BytesIO(b'fixture-secret'))
        client = Client([error])
        result = probe.probe(client, "fixture-api", "fixture-key", False)
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

    def test_protocol_extraction_and_hmac_golden(self):
        source = "const picaApi = 'https://picaapi.picacomic.com';\nconst _apiKey = 'fixture-api';\nconst _signingKey = r'fixture-key';"
        self.assertEqual(probe.protocol_constants(source), ("fixture-api", "fixture-key"))
        with mock.patch.object(probe.time, "time", return_value=1700000000), \
                mock.patch.object(probe.secrets, "choice", return_value="A"):
            request = probe.request_for("fixture-api", "fixture-key", False)
        self.assertEqual(request.get_header("Signature"),
                         "fab4da908b9feaf9e6fbc399f2bf0f512ad116396a44df0b5e778c45fb2e030e")
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


if __name__ == "__main__":
    unittest.main()
