"""Create local plugin junctions when Windows denies unprivileged symlinks.

Does not change the SDK or pub cache, remove files, or require Developer Mode.
Flutter accepts existing links; run after dependency resolution, before build.
"""
import json, os, re, subprocess
from datetime import datetime
from pathlib import Path

root = Path(__file__).resolve().parents[1]
data = json.loads((root/'.flutter-plugins-dependencies').read_text(encoding='utf-8'))
count = 0
for platform in ('windows','linux'):
    folder = root/platform/'flutter/ephemeral/.plugin_symlinks'
    folder.mkdir(parents=True,exist_ok=True)
    for plugin in data['plugins'].get(platform,[]):
        name=plugin['name']
        if not name.replace('_','').isalnum():
            raise ValueError('Invalid plugin name')
        target=Path(plugin['path']).resolve(strict=True)
        link=folder/name
        if os.path.lexists(link):
            if link.resolve()!=target:
                if link.is_dir() and not link.is_symlink() and not link.is_junction():
                    preserved=folder/(name+'.preserved-'+datetime.now().strftime('%Y%m%d%H%M%S'))
                    link.rename(preserved)
                else:
                    raise ValueError('Existing plugin link has a different target: '+name)
            else:
                continue
        result=subprocess.run(['cmd','/c','mklink','/J',str(link),str(target)],capture_output=True)
        if result.returncode or not link.is_dir():
            raise RuntimeError('Cannot create plugin junction: '+name)
        count+=1
print(f'Prepared {count} plugin junctions')
# Resolving dependencies can stop after metadata/junction creation but before
# Flutter refreshes its native registrant. A --no-pub build would then succeed
# with missing method channels. Let Flutter regenerate these files itself.
cmake = (root/'windows/flutter/generated_plugins.cmake').read_text(encoding='utf8')
registrant = (root/'windows/flutter/generated_plugin_registrant.cc').read_text(encoding='utf8')
ffi_section = re.search(r'list\(APPEND FLUTTER_FFI_PLUGIN_LIST\s+(.*?)\)', cmake, re.S)
ffi_plugins = set(ffi_section.group(1).split()) if ffi_section else set()
missing = [p['name'] for p in data['plugins'].get('windows', [])
           if p.get('native_build', True) and (
               p['name'] not in cmake or
               (p['name'] not in ffi_plugins and p['name'] not in registrant))]
if missing:
    raise RuntimeError('Native plugin registration is stale; run flutter pub get '
                       'again after preparing junctions: '+', '.join(missing))
