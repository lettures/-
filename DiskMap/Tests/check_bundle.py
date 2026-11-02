import plistlib, subprocess, sys
from pathlib import Path
app = Path(sys.argv[1]).resolve()
p = plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert p['CFBundleShortVersionString'] == '0.6.0'
assert p['LSMinimumSystemVersion'] == '14.0'
exe = app/'Contents/MacOS'/p['CFBundleExecutable']
assert exe.is_file() and exe.stat().st_mode & 0o111
assert 'arm64' in subprocess.check_output(['file', str(exe)], text=True)
subprocess.run(['codesign','--verify','--strict',str(app)],check=True)
s = subprocess.run(['codesign','-dv',str(app)],capture_output=True,text=True).stderr
assert 'Signature=adhoc' in s and 'TeamIdentifier=not set' in s
print('PASS: plist, executable, arm64, macOS 14, version, ad-hoc signature')
