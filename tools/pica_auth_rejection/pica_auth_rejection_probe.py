"""Two reserved-account rejection requests; never print credentials or remote text."""

import contextlib
import hashlib
import hmac
import json
import pathlib
import re
import secrets
import signal
import ssl
import sys
import time
import urllib.error
import urllib.request


ENDPOINT = "https://picaapi.picacomic.com/auth/sign-in"
FIXTURE_ACCOUNT = "fixture-reader@example.invalid"
SOURCE = pathlib.Path("lib/core/source/picacomic/picacomic_client.dart")
OUTPUT = pathlib.Path("pica-auth-rejection-result.json")
TIMEOUT_SECONDS = 20
MAX_BYTES = 8192
MESSAGE_CLASSES = {
    "success": "success",
    "unauthorized": "unauthorized",
    "unauthorised": "unauthorized",
    "invalid token": "invalidToken",
    "token expired": "expiredToken",
    "invalid signature": "invalidSignature",
    "invalid api key": "invalidApiKey",
    "invalid timestamp": "invalidTimestamp",
    "request expired": "expiredRequest",
    "invalid email or password": "invalidCredentials",
    "bad request": "badRequest",
    "not found": "notFound",
}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


@contextlib.contextmanager
def request_deadline():
    # The diagnostic runner is Ubuntu. Bound DNS, TLS and a slow body together,
    # rather than resetting a socket timeout whenever a peer drips another byte.
    if not hasattr(signal, "setitimer"):
        raise RuntimeError("POSIX request deadline unavailable")
    def expired(_number, _frame):
        raise TimeoutError()
    previous_handler = signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, TIMEOUT_SECONDS)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)


def protocol_constants(source):
    api = re.search(r"const picaApi = '([^']+)';", source)
    api_key = re.search(r"const _apiKey = '([^']+)';", source)
    signing_key = re.search(r"const _signingKey\s*=\s*r'([^']+)';", source)
    if not all((api, api_key, signing_key)) or api[1] + "/auth/sign-in" != ENDPOINT:
        raise ValueError("Protocol source layout changed")
    return api_key[1], signing_key[1]


def request_for(api_key, signing_key, body, include_empty_auth):
    timestamp = str(int(time.time()))
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    nonce = "".join(secrets.choice(alphabet) for _ in range(32))
    raw = ("auth/sign-in" + timestamp + nonce + "POST" + api_key).lower()
    signature = hmac.new(signing_key.encode(), raw.encode(), hashlib.sha256).hexdigest()
    headers = {
        "api-key": api_key,
        "app-channel": "1",
        "app-version": "2.2.1.3.3.4",
        "app-uuid": "defaultUuid",
        "app-platform": "android",
        "app-build-version": "44",
        "User-Agent": "okhttp/3.8.1",
        "accept": "application/vnd.picacomic.com.v1+json",
        "image-quality": "original",
        "Content-Type": "application/json; charset=UTF-8",
        "time": timestamp,
        "nonce": nonce,
        "signature": signature,
    }
    if include_empty_auth:
        headers["authorization"] = ""
    return urllib.request.Request(ENDPOINT, data=body, headers=headers, method="POST")


def classify_body(body):
    if len(body) > MAX_BYTES:
        return {"bodyClass": "oversize", "messageClass": "unavailable"}
    try:
        decoded = json.loads(body)
    except (ValueError, UnicodeError, RecursionError):
        return {"bodyClass": "nonJSON", "messageClass": "unavailable"}
    is_api = isinstance(decoded, dict) and type(decoded.get("code")) is int
    message = decoded.get("message") if isinstance(decoded, dict) else None
    return {
        "bodyClass": "jsonAPI" if is_api else "otherJSON",
        "messageClass": MESSAGE_CLASSES.get(message.lower(), "unknown")
        if isinstance(message, str) else "unavailable",
    }


def opener():
    context = ssl.create_default_context()
    # No environment proxy or netrc credentials may become part of this probe.
    return urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=context),
        NoRedirect(),
    )


def probe(client, request, include_empty_auth):
    result = {"authorizationMode": "empty" if include_empty_auth else "omitted"}
    try:
        with request_deadline():
            try:
                response = client.open(
                    request,
                    timeout=TIMEOUT_SECONDS,
                )
            except urllib.error.HTTPError as error:
                response = error
            with response:
                status = int(response.code)
                result.update({"requestStatus": "httpResponse", "httpStatus": status})
                if 200 <= status < 300:
                    # Never read or parse a potentially successful session body.
                    result.update({"requestStatus": "unexpectedSuccess",
                                   "responseClass": "unexpectedSuccess"})
                    return result
                # One bounded read; no body/header/error text enters the result.
                body = response.read(MAX_BYTES + 1)
                result.update(classify_body(body))
                if 300 <= status < 400:
                    result["responseClass"] = "redirectRejected"
                else:
                    result["responseClass"] = "directResponse"
    except (urllib.error.URLError, OSError, TimeoutError, ssl.SSLError) as error:
        result.update({"requestStatus": "transportFailure", "errorType": type(error).__name__})
    return result


def run(client, api_key, signing_key):
    # Reserved .invalid account and one random synthetic password per run.
    # Neither can be provided through arguments, environment or configuration.
    body = json.dumps({"email": FIXTURE_ACCOUNT,
                       "password": "fixture-" + secrets.token_urlsafe(24)},
                      separators=(",", ":")).encode()
    # Each request gets its own normal nonce and current signed timestamp.
    results = [probe(client, request_for(api_key, signing_key, body, mode), mode)
               for mode in (False, True)]
    failed = any(item["requestStatus"] in {"transportFailure", "unexpectedSuccess"}
                 for item in results)
    return {
        "scope": "twoReservedAccountSignInRejections",
        "realAccountAcceptance": "notTested",
        "runStatus": "failed" if failed else "httpResponsesRecorded",
        "comparisonLimit": "syntheticRejectionDoesNotProveRealAccountAcceptance",
        "results": results,
    }


def main():
    exit_code = 1
    try:
        api_key, signing_key = protocol_constants(SOURCE.read_text(encoding="utf-8"))
        report = run(opener(), api_key, signing_key)
        exit_code = 1 if report["runStatus"] == "failed" else 0
    except Exception as error:
        # Never serialize exception messages, causes or tracebacks.
        report = {"scope": "twoReservedAccountSignInRejections", "realAccountAcceptance": "notTested",
                  "runStatus": "failed", "errorType": type(error).__name__}
    OUTPUT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
