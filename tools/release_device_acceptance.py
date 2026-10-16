"""Observe installed release UI and resources; never record body/account/log text.

No target APK replacement, uninstall, data clear, fixture, or account mutation.
The soak drives existing public reading history through ordinary Android UI.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET

ADB = r'C:\Android\Sdk\platform-tools\adb.exe'
PACKAGE = 'io.github.hyperionhxh.triomi'
BOOKS = ['年度最垃圾伪圣女', '負債兩千萬的班級偶像，被邊緣人的我買下來了', 'Space Boy']


class Device:
    def __init__(self, serial):
        self.serial = serial

    def call(self, *args, timeout=20):
        result = subprocess.run([ADB, '-s', self.serial, *args],
                                capture_output=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError('ADB operation failed')
        return result.stdout.decode('utf8', errors='replace')

    def ui(self):
        remote = '/sdcard/triomi-release-ui.xml'
        self.call('shell', 'uiautomator', 'dump', remote)
        xml = self.call('shell', 'cat', remote)
        self.call('shell', 'rm', remote)
        return [((n.get('text') or n.get('content-desc') or '').strip(), n.get('bounds', ''))
                for n in ET.fromstring(xml).iter('node')]

    def tap(self, node):
        a, b, c, d = map(int, re.findall(r'\d+', node[1]))
        self.call('shell', 'input', 'tap', str((a + c) // 2), str((b + d) // 2))

    def text(self, query, nodes=None):
        nodes = self.ui() if nodes is None else nodes
        return next((n for n in nodes if n[0] == query), None) or next(
            (n for n in nodes if n[0].startswith(query)), None)

    def start(self):
        self.call('shell', 'am', 'start', '-n', PACKAGE + '/.MainActivity')

    def back(self):
        self.call('shell', 'input', 'keyevent', '4')

    def history(self):
        for _ in range(8):
            nodes = self.ui()
            if any(t == '全部历史' for t, _ in nodes) and any(
                    t == '清空历史' for t, _ in nodes):
                return nodes
            history = self.text('全部观看与阅读历史', nodes)
            if history:
                self.tap(history)
                continue
            profile = self.text('切换到我的', nodes)
            if profile:
                self.tap(profile)
                continue
            self.back()
        raise RuntimeError('Unified reading history unavailable')

    def sample(self):
        try:
            pid = self.call('shell', 'pidof', PACKAGE).strip().split()
        except RuntimeError:
            pid = []
        if not pid:
            return {'running': False}
        info = self.call('shell', 'dumpsys', 'meminfo', PACKAGE)
        status = self.call('shell', 'cat', '/proc/' + pid[0] + '/status')
        pss = re.search(r'TOTAL PSS:\s*(\d+)', info) or re.search(
            r'^\s*TOTAL\s+(\d+)', info, re.M)
        threads = re.search(r'Threads:\s*(\d+)', status)
        try:
            fd = self.call('shell', 'ls', '/proc/' + pid[0] + '/fd')
        except RuntimeError:
            fd = ''
        return {'running': True, 'pid': int(pid[0]),
                'pssKiB': int(pss[1]) if pss else None,
                'threads': int(threads[1]) if threads else None,
                'fileDescriptors': len(fd.split()) if re.fullmatch(r'[\d\s]+', fd) else None,
                'fdScope': 'shell readable proc only; null means OS denied'}

    def summary(self):
        nodes = self.ui()
        texts = [t for t, _ in nodes]
        return {'visibleNodeCount': len(nodes),
                'pages': list(dict.fromkeys(p for t in texts for p in re.findall(r'\b\d+\s*/\s*\d+\b', t))),
                'knownBooks': [b for b in BOOKS if any(t.startswith(b) for t in texts)],
                'continueReading': any(t.startswith('继续阅读') for t in texts),
                'offlineFallback': any(t.startswith('离线模式') for t in texts),
                'retry': '重试' in texts,
                'catalog': [t for t in texts if re.fullmatch(r'目录（\d+）', t)],
                'chapterControls': [t for t in texts if t in ('上一章', '下一章', '目录', '设置', '返回')],
                'resource': self.sample()}


def soak(device, output, seconds):
    started = time.monotonic()
    record = {'serial': device.serial, 'status': 'running', 'targetSeconds': seconds,
              'scope': 'installed release UI; real persisted LK/LNS/Webtoons; no fixture',
              'cycles': [], 'samples': [], 'homeResume': 0, 'independentRestarts': 0}
    def save():
        record['elapsedSeconds'] = round(time.monotonic() - started, 1)
        output.write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding='utf8')
    before_crashes = device.call('logcat', '-d', '-b', 'crash')
    try:
        while time.monotonic() - started < seconds:
            book = BOOKS[len(record['cycles']) % len(BOOKS)]
            cycle = {'kind': ['lns', 'lk', 'webtoons'][BOOKS.index(book)], 'entered': False,
                     'pageActions': 0}
            record['cycles'].append(cycle)
            try:
                nodes = device.history()
                target = device.text(book, nodes)
                if not target:
                    raise RuntimeError('Known reading history missing')
                device.tap(target)
                deadline = time.monotonic() + 65
                while time.monotonic() < deadline:
                    nodes = device.ui()
                    button = device.text('继续阅读', nodes)
                    if button:
                        cycle['detailOfflineFallback'] = any(t.startswith('离线模式') for t, _ in nodes)
                        device.tap(button)
                        break
                else:
                    raise RuntimeError('Continue button unavailable')
                deadline = time.monotonic() + 40
                while time.monotonic() < deadline:
                    summary = device.summary()
                    if summary['pages']:
                        break
                else:
                    raise RuntimeError('Reader indicator unavailable')
                cycle['entered'] = True
                cycle['initialPage'] = summary['pages'][0]
                size = device.call('shell', 'wm', 'size')
                width, height = map(int, re.findall(r'(\d+)x(\d+)', size)[-1])
                for i in range(8):
                    device.call('shell', 'input', 'tap', str(int(width * (.85 if i % 4 < 2 else .15))), str(height // 2))
                    time.sleep(.3)
                    cycle['pageActions'] += 1
                final = device.summary()
                cycle['finalPage'] = final['pages']
                record['samples'].append({'elapsedSeconds': round(time.monotonic() - started, 1), **final['resource']})
                if len(record['cycles']) % 5 == 0:
                    device.call('shell', 'input', 'keyevent', 'KEYCODE_HOME')
                    time.sleep(2)
                    device.start()
                    record['homeResume'] += 1
                device.back()
                if len(record['cycles']) % 10 == 0:
                    device.call('shell', 'am', 'force-stop', PACKAGE)
                    device.start()
                    record['independentRestarts'] += 1
            except Exception as error:
                cycle['failureType'] = type(error).__name__
                device.start()
            save()
            time.sleep(8)
        crashes = device.call('logcat', '-d', '-b', 'crash')
        expression = r'Process: ' + re.escape(PACKAGE) + r'\b'
        record['newCrashMarkers'] = max(0, len(re.findall(expression, crashes)) - len(re.findall(expression, before_crashes)))
        record['status'] = 'passed' if all(c['entered'] and c.get('finalPage') for c in record['cycles']) and not record['newCrashMarkers'] else 'partial'
        record['limits'] = 'UI indicator verifies navigation, not pixel decoding; no forced network outage or chapter switching in this run; FD sampling may be denied'
    finally:
        save()
    print(json.dumps({'status': record['status'], 'elapsedSeconds': record['elapsedSeconds'],
                      'cycles': len(record['cycles']), 'entered': sum(c['entered'] for c in record['cycles'])}))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', required=True, choices=['emulator-5554', 'emulator-5556', 'emulator-5558'])
    parser.add_argument('--output', type=Path)
    parser.add_argument('--seconds', type=int, default=1800)
    parser.add_argument('action', choices=['summary', 'soak', 'abi', 'package'])
    args = parser.parse_args()
    device = Device(args.device)
    if args.action == 'summary':
        record = device.summary()
        record['serial'] = args.device
        if args.output:
            args.output.write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding='utf8')
        print(json.dumps(record, ensure_ascii=False))
    elif args.action == 'soak':
        if not args.output:
            parser.error('--output required')
        soak(device, args.output, args.seconds)
    else:
        if args.action == 'abi':
            result = device.call('shell', 'am', 'instrument', '-w', PACKAGE + '.test/' + PACKAGE + '.ReleaseAbiInstrumentation', timeout=90)
            record = {'serial': args.device, 'status': 'passed' if 'OK (3 release ABI checks)' in result else 'failed',
                      'checks': ['Preference', 'native Zstd decode', 'Injekt Json and JSON/Okio StringSerializer'],
                      'targetLoader': 'targetContext.classLoader', 'targetReplaced': False}
        else:
            remote = device.call('shell', 'pm', 'path', PACKAGE).strip().removeprefix('package:')
            digest = device.call('shell', 'sha256sum', remote).split()[0]
            record = {'serial': args.device, 'installedSha256': digest, 'preserveData': True}
        if args.output:
            args.output.write_text(json.dumps(record, indent=2), encoding='utf8')
        print(json.dumps(record))


if __name__ == '__main__':
    main()
