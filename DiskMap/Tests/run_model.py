from pathlib import Path
import subprocess, tempfile, sys
root = Path(__file__).resolve().parents[1]
full = (root / 'Sources/DiskMap.swift').read_text()
s = full.split('struct MapView:')[0] + full[full.index('func size(_'):full.index('struct DuplicateView:')]
with tempfile.TemporaryDirectory() as tmp:
    p = Path(tmp) / 'model.swift'
    p.write_text(s + (root/'Tests/ModelChecks.swift').read_text())
    binary = Path(tmp)/'model-checks'
    subprocess.run(['swiftc','-Onone','-parse-as-library','-module-cache-path',str(Path(tmp)/'cache'),str(p),'-o',str(binary)],check=True)
    subprocess.run([str(binary),*sys.argv[1:]],check=True)
