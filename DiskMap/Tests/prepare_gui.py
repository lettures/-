"""Create only disposable fixtures under the supplied directory; may create one million files."""
from pathlib import Path
import argparse
p=argparse.ArgumentParser();p.add_argument('destination');p.add_argument('--stress',action='store_true');a=p.parse_args()
r=Path(a.destination).resolve();r.mkdir(parents=True,exist_ok=True)
(r/'子目录').mkdir(exist_ok=True)
(r/'大文件.bin').write_bytes(b'x'*1048576)
(r/'子目录'/'内部.bin').write_bytes(b'x'*524288)
(r/'无权限').mkdir(exist_ok=True);(r/'无权限').chmod(0)
if a.stress:
 s=r/'压力目录';s.mkdir(exist_ok=True)
 for i in range(1000000): (s/str(i)).touch()
print(r)
print('Restore only the test directory permission after testing: chmod 700',r/'无权限')
