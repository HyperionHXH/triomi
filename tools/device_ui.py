"""Local emulator acceptance helper; never clears application data."""
import argparse
import base64
import os
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ADB = os.environ.get('TRIOMI_ADB', r'C:\Android\Sdk\platform-tools\adb.exe')
DEVICE = os.environ.get('ANDROID_SERIAL')

def adb(*args):
    target = ['-s', DEVICE] if DEVICE else []
    return subprocess.run([ADB, *target, *args], check=True, capture_output=True).stdout.decode('utf-8', errors='replace')

def snapshot():
    result = adb('shell', 'uiautomator', 'dump', '/sdcard/triomi-ui.xml')
    if 'ERROR' in result:
        raise RuntimeError(result)
    path = Path(tempfile.gettempdir()) / 'triomi-ui.xml'
    adb('pull', '/sdcard/triomi-ui.xml', str(path))
    return list(ET.parse(path).iter('node'))

def main():
    global DEVICE
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', default=DEVICE)
    parser.add_argument('action', choices=['snapshot', 'tap', 'input', 'shot'])
    parser.add_argument('value', nargs='?', default='')
    args = parser.parse_args()
    DEVICE = args.device
    if args.action == 'input':
        value = base64.b64encode(args.value.encode()).decode()
        print(adb('shell','am','broadcast','-a','ADB_INPUT_B64','--es','msg',value))
    elif args.action == 'shot':
        adb('shell','screencap','-p','/sdcard/triomi-shot.png')
        adb('pull','/sdcard/triomi-shot.png',args.value)
    else:
        nodes = snapshot()
        if args.action == 'tap':
            exact = [n for n in nodes if (n.get('text') or n.get('content-desc') or '') == args.value]
            if exact:
                nodes = exact
        for node in nodes:
            text = node.get('text') or node.get('content-desc') or ''
            if not text:
                continue
            if args.action == 'snapshot':
                print(text, node.get('bounds'))
            elif args.value in text:
                x1,y1,x2,y2 = map(int,re.findall(r'\d+',node.get('bounds')))
                print(adb('shell','input','tap',str((x1+x2)//2),str((y1+y2)//2)))
                return
        if args.action == 'tap':
            raise RuntimeError('No visible matching control: '+args.value)

if __name__ == '__main__':
    main()
