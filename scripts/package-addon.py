from pathlib import Path
import hashlib
import json
import re
import zipfile

root = Path(__file__).resolve().parent.parent
name = 'AzerothSurvivorsRecorder'
source = root / 'addon' / name
out = root / 'artifacts'
out.mkdir(exist_ok=True)
version = re.search(r'^## Version: (.+)$', (source / (name + '.toc')).read_text(), re.M)[1].strip()
assert re.search(r'local VERSION = "' + re.escape(version) + '"', (source / (name + '.lua')).read_text())
package = out / (name + '-' + version + '.zip')
files = [name + '.toc', 'SpellTooltips.lua', 'Jewelry.lua', name + '.lua']
with zipfile.ZipFile(package, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for filename in files:
        entry = zipfile.ZipInfo(name + '/' + filename, date_time=(2026, 1, 1, 0, 0, 0))
        entry.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(entry, (source / filename).read_bytes())
with zipfile.ZipFile(package) as archive:
    assert sorted(archive.namelist()) == sorted(name + '/' + f for f in files)
    assert archive.testzip() is None
    for filename in files:
        assert archive.read(name + '/' + filename) == (source / filename).read_bytes()
result = {'package':str(package), 'sha256':hashlib.sha256(package.read_bytes()).hexdigest(), 'files':files, 'verified':True}
(out / 'addon-package.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
print(json.dumps(result))
