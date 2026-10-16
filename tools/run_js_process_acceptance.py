"""Independent OS watchdog for hostile JS device tests. No account data."""
import argparse
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--device', required=True, choices=['emulator-5554', 'emulator-5556', 'windows'])
parser.add_argument('--log', type=Path, required=True)
args = parser.parse_args()
env = os.environ.copy()
env['ANDROID_HOME'] = env['ANDROID_SDK_ROOT'] = r'C:\Android\Sdk'
env['JAVA_HOME'] = r'C:\Program Files\Eclipse Adoptium\jdk-21.0.12.101-hotspot'
flutter = r'C:\Users\MiunaH\.workbuddy\binaries\flutter\sdk\bin\flutter.bat'
with args.log.open('w', encoding='utf-8') as log:
    env['PATH'] = r'D:\noval_and_manga\_tools\bin' + os.pathsep + env['PATH']
    command = [flutter, 'test', 'integration_test/js_process_live_test.dart', '--no-pub', '-d', args.device]
    if args.device == 'windows':
        build = subprocess.run([flutter,'build','windows','--debug','--no-pub','-t','tools/windows_js_acceptance.dart'], stdout=log, stderr=subprocess.STDOUT, env=env, timeout=300)
        if build.returncode:
            raise SystemExit(build.returncode)
        command = [str(Path('build/windows/x64/runner/Debug/triomi.exe').resolve())]
        env['TRIOMI_JS_ACCEPTANCE_OUTPUT'] = str(Path('docs/delivery/evidence/C125-js-windows.json').resolve())
    if args.device != 'windows':
        command.append('--no-uninstall')
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, env=env)
    try:
        code = process.wait(timeout=300)
    except subprocess.TimeoutExpired:
        if args.device != 'windows':
            subprocess.run([r'C:\Android\Sdk\platform-tools\adb.exe', '-s', args.device, 'shell', 'am', 'force-stop', 'io.github.hyperionhxh.triomi'], capture_output=True)
        subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'], capture_output=True)
        code = 124
raise SystemExit(code)
