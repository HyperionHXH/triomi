"""External device resource/lifecycle sampling, without saving app log text."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--device', required=True, choices=['emulator-5554', 'emulator-5556'])
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--seconds', type=int, default=420)
args = parser.parse_args()
adb = r'C:\Android\Sdk\platform-tools\adb.exe'
package = 'io.github.hyperionhxh.triomi'
def call(*command):
    return subprocess.run([adb, '-s', args.device, *command], capture_output=True, text=True, encoding='utf8', errors='replace', timeout=15).stdout

started = time.monotonic()
samples = []
lifecycle = 0
while time.monotonic()-started < args.seconds:
    pid = call('shell', 'pidof', package).strip()
    if pid:
        stats = call('shell', 'dumpsys', 'meminfo', package)
        pss = re.search(r'TOTAL PSS:\s*(\d+)', stats) or re.search(r'^\s*TOTAL\s+(\d+)', stats, re.M)
        status = call('shell', 'cat', f'/proc/{pid.split()[0]}/status')
        threads = re.search(r'Threads:\s*(\d+)', status)
        samples.append({'elapsedSeconds':round(time.monotonic()-started,1),'pssKiB':int(pss[1]) if pss else None,'threads':int(threads[1]) if threads else None})
        if len(samples) in (10,20,30):
            call('shell','input','keyevent','KEYCODE_HOME')
            time.sleep(2)
            call('shell','am','start','-n',f'{package}/.MainActivity')
            lifecycle += 1
    args.output.write_text(json.dumps({'samples':samples,'homeResumeCycles':lifecycle,'elapsedSeconds':round(time.monotonic()-started,1)}, indent=2), encoding='utf8')
    time.sleep(10)
logs = call('logcat','-d','-b','crash')
record={'samples':samples,'homeResumeCycles':lifecycle,'elapsedSeconds':round(time.monotonic()-started,1),'triomiCrashMarkers':len(re.findall(r'Process: '+re.escape(package)+r'\b',logs)),'crashScope':'current emulator crash buffer, raw text not saved'}
args.output.write_text(json.dumps(record,indent=2),encoding='utf8')
