from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / "Sources/DiskMap.swift").read_text()
core = s[:s.index("@MainActor final class Model")] + s[s.index("func size(_"):s.index("extension Model") ]
layout = ""
with tempfile.TemporaryDirectory() as tmp:
    p = Path(tmp) / "checks.swift"
    p.write_text(core + layout + (root / "Tests/CoreChecks.swift").read_text())
    subprocess.run(["swift", "-module-cache-path", str(Path(tmp)/"cache"), str(p)], check=True)
