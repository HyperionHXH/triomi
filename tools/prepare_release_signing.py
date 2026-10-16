"""Create private production signing outside the checkout; never print secrets."""
import json
import os
from pathlib import Path
import secrets
import subprocess

folder = Path(os.environ['USERPROFILE']) / '.triomi' / 'signing'
folder.mkdir(parents=True, exist_ok=True)
identity = subprocess.run(['whoami'], capture_output=True, text=True, check=True).stdout.strip()
subprocess.run(['icacls', str(folder), '/inheritance:r', '/grant:r', identity + ':(OI)(CI)F', '*S-1-5-18:(OI)(CI)F'], capture_output=True, check=True)
keystore = folder / 'triomi-release.p12'
properties = folder / 'signing.properties'
if keystore.exists() != properties.exists():
    raise SystemExit('Existing signing material incomplete; preserved unchanged')
if not keystore.exists():
    password = secrets.token_urlsafe(48)
    env = os.environ.copy()
    env['TRIOMI_KEYSTORE_PASSWORD'] = password
    result = subprocess.run([
        r'C:\Program Files\Eclipse Adoptium\jdk-21.0.12.101-hotspot\bin\keytool.exe',
        '-genkeypair', '-storetype', 'PKCS12', '-keystore', str(keystore),
        '-alias', 'triomi-release', '-keyalg', 'RSA', '-keysize', '4096',
        '-validity', '10000', '-dname', 'CN=Triomi Release, O=Triomi',
        '-storepass:env', 'TRIOMI_KEYSTORE_PASSWORD', '-keypass:env', 'TRIOMI_KEYSTORE_PASSWORD',
    ], capture_output=True, env=env)
    if result.returncode:
        raise SystemExit('Key generation failed; diagnostic values withheld')
    properties.write_text('storeFile=' + keystore.as_posix() + '\nstorePassword=' + password + '\nkeyAlias=triomi-release\nkeyPassword=' + password + '\n', encoding='ascii')
    del password
    env.pop('TRIOMI_KEYSTORE_PASSWORD', None)
print(json.dumps({'keystore': str(keystore), 'properties': str(properties), 'createdOrReused': True}))
