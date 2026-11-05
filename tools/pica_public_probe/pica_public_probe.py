"""Two anonymous, read-only requests; never print remote text or request headers."""

import hashlib
import hmac
import json
import pathlib
import re
import secrets
import ssl
import sys
import time
import urllib.error
import urllib.request


ENDPOINT = "https://picaapi.picacomic.com/categories"
SOURCE = pathlib.Path("lib/core/source/picacomic/picacomic_client.dart")
OUTPUT = pathlib.Path("pica-public-probe-result.json")
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


def protocol_constants(source):
    api = re.search(r"const picaApi = '([^']+)';", source)
    api_key = re.search(r"const _apiKey = '([^']+)';", source)
    signing_key = re.search(r"const _signingKey\s*=\s*r'([^']+)';", source)
    if not all((api, api_key, signing_key)) or api[1] + "/categories" != ENDPOINT:
        raise ValueError("Protocol source layout changed")
    return api_key[1], signing_key[1]


def request_for(api_key, signing_key, include_empty_auth):
    timestamp = str(int(time.time()))
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    nonce = "".join(secrets.choice(alphabet) for _ in range(32))
    raw = ("categories" + timestamp + nonce + "GET" + api_key).lower()
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
    # No API to supply credentials, arbitrary destinations, methods or payloads.
    return urllib.request.Request(ENDPOINT, headers=headers, method="GET")


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


def probe(client, api_key, signing_key, include_empty_auth):
    result = {"authorizationMode": "empty" if include_empty_auth else "omitted"}
    try:
        try:
            response = client.open(
                request_for(api_key, signing_key, include_empty_auth),
                timeout=TIMEOUT_SECONDS,
            )
        except urllib.error.HTTPError as error:
            response = error
        with response:
            status = int(response.code)
            # One bounded read; no body/header/error text enters the result.
            body = response.read(MAX_BYTES + 1)
            result.update({"requestStatus": "httpResponse", "httpStatus": status})
            result.update(classify_body(body))
            if 300 <= status < 400:
                result["responseClass"] = "redirectRejected"
            else:
                result["responseClass"] = "directResponse"
    except (urllib.error.URLError, OSError, TimeoutError, ssl.SSLError) as error:
        result.update({"requestStatus": "transportFailure", "errorType": type(error).__name__})
    return result


def run(client, api_key, signing_key):
    results = [probe(client, api_key, signing_key, mode) for mode in (False, True)]
    failed = any(item["requestStatus"] == "transportFailure" for item in results)
    return {
        "scope": "twoAnonymousCategoryGETs",
        "accountAcceptance": "notTested",
        "runStatus": "failed" if failed else "httpResponsesRecorded",
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
        report = {"scope": "twoAnonymousCategoryGETs", "accountAcceptance": "notTested",
                  "runStatus": "failed", "errorType": type(error).__name__}
    OUTPUT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
