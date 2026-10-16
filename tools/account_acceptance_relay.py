"""Run real Android account acceptance without embedding credentials in an APK.

The credential file stays on the host. A one-use, short-lived loopback endpoint
passes it over adb reverse to the integration test. No request logging, fixture
responses, tokens, cookies, or passwords are saved by this helper.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def read_accounts(path):
    accounts = {}
    current = None
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        label, sep, value = line.replace("：", ":").partition(":")
        if label.strip().lower() in ("lk", "lns"):
            current = label.strip().lower()
            # LK:账号:value; LNS:value
            if value.startswith("账号:"):
                value = value.partition(":")[2]
            accounts[current] = {"account": value.strip()}
        elif sep and current:
            accounts[current]["password"] = value.strip()
    if any(not accounts.get(k, {}).get(f) for k in ("lk", "lns")
           for f in ("account", "password")):
        raise ValueError("Account file structure is unsupported (values hidden)")
    return accounts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credentials", type=Path, required=True)
    parser.add_argument("--flutter", required=True)
    parser.add_argument("--phase", choices=("login", "resume"), default="login")
    parser.add_argument("--device", default="emulator-5554")
    parser.add_argument("--port", type=int, default=18763)
    args = parser.parse_args()
    accounts = read_accounts(args.credentials) if args.phase == "login" else {}
    expires = time.monotonic() + 900
    used = False

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            nonlocal used
            if self.path != "/credentials" or used or time.monotonic() > expires:
                self.send_error(404)
                return
            used = True
            body = json.dumps(accounts).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            accounts.clear()

    adb = str(Path(os.environ.get("ANDROID_SDK_ROOT", r"C:\Android\Sdk")) /
              "platform-tools" / "adb.exe")
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    endpoint = f"tcp:{args.port}"
    env = os.environ.copy()
    env["ANDROID_HOME"] = env["ANDROID_SDK_ROOT"] = str(Path(adb).parents[1])
    try:
        subprocess.run([adb, "-s", args.device, "reverse", endpoint, endpoint],
                       check=True, capture_output=True)
        subprocess.run([adb, "-s", args.device, "shell", "am", "force-stop",
                        "io.github.hyperionhxh.triomi"], check=True, capture_output=True)
        result = subprocess.run([
            args.flutter, "test", "integration_test/novel_account_live_test.dart",
            "--no-pub", "--no-uninstall", "-d", args.device,
            f"--dart-define=NOVEL_ACCOUNT_PHASE={args.phase}",
            f"--dart-define=NOVEL_ACCOUNT_RELAY_PORT={args.port}",
        ], env=env)
        raise SystemExit(result.returncode)
    finally:
        accounts.clear()
        server.shutdown()
        server.server_close()
        subprocess.run([adb, "-s", args.device, "reverse", "--remove", endpoint],
                       capture_output=True)


if __name__ == "__main__":
    main()
