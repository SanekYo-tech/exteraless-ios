"""Fresh CPython 3.12 import checks, each bounded to 20 seconds.

Only pinned distributions and tiny in-memory image/XML/YAML/HTML fixtures run.
No client plugins, debugger connection, process attach or device installation.
"""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from native_dependencies import read_lock, unpack_zip, write_json
from pinned_download import digest, fetch


ROOT = Path(__file__).resolve().parents[2]
NATIVE_SCRIPT = r'''
import io,json,sys,traceback
assert sys.version_info[:2] == (3,12)
root, name, module, mode, report = sys.argv[1:]
sys.path.insert(0, root)
out = dict(package=name, python=sys.version, platform=sys.platform, mode=mode,
           check_multi_interp_extensions=1, own_gil_supported=False)
if mode == 'main':
    if name == 'pillow':
        from PIL import Image, _imaging
        buffer=io.BytesIO(); Image.new('RGB',(3,2),(12,34,56)).save(buffer,format='PNG')
        buffer.seek(0)
        with Image.open(buffer) as image:
            assert image.size == (3,2) and image.getpixel((1,1)) == (12,34,56)
        out['native_module_path']=_imaging.__file__
    else:
        from lxml import etree
        value=etree.fromstring(b'<root><value>native</value></root>')
        assert value.xpath('string(value)') == 'native'
        assert etree.tostring(value) == b'<root><value>native</value></root>'
        out['native_module_path']=etree.__file__
    out['functional_check']=True
else:
    import _xxsubinterpreters as interpreters
    # CPython 3.12 create(isolated=True) uses _PyInterpreterConfig_INIT:
    # check_multi_interp_extensions=1 and PyInterpreterConfig_OWN_GIL.
    child=interpreters.create(isolated=True)
    try:
        interpreters.run_string(child, 'import sys;sys.path.insert(0,'+repr(root)+');__import__('+repr(module)+')')
        out['own_gil_supported']=True
        out['result']='imported'
    except interpreters.RunFailedError as error:
        out['result']='rejected';out['error']=str(error)
        assert 'does not support loading in subinterpreters' in str(error) or 'Interpreter change detected' in str(error), str(error)
    finally:
        interpreters.destroy(child)
out['native_completed']=True
with open(report,'w',encoding='utf-8') as f:json.dump(out,f,indent=2)
'''

PURE_SCRIPT = r'''
import json,sys
assert sys.version_info[:2] == (3,12)
vendor,report=sys.argv[1:]
code = ''' + '"""' + r'''
import sys, json, io
sys.path.insert(0, VENDOR)
from bs4 import BeautifulSoup
import soupsieve,yaml,debugpy,requests,packaging,cachetools,typing_extensions
assert BeautifulSoup('<ul><li class="x">ok</li></ul>','html.parser').select_one('li.x').text == 'ok'
assert yaml.safe_load('ключ: [1, true]')['ключ'] == [1, True]
assert yaml.safe_load(yaml.safe_dump({'items':[1,'é']})) == {'items':[1,'é']}
assert yaml.__with_libyaml__ is False
assert debugpy.__version__ == '1.8.22'
assert requests.Request('GET','https://example.invalid').prepare().method == 'GET'
''' + '"""' + r'''
exec('VENDOR='+repr(vendor)+'\n'+code)
import _xxsubinterpreters as interpreters
for unused in range(2):
    child=interpreters.create(isolated=True)
    try:interpreters.run_string(child,'VENDOR='+repr(vendor)+'\n'+code)
    finally:interpreters.destroy(child)
with open(report,'w',encoding='utf-8') as f:
    json.dump(dict(ok=True,python=sys.version,platform=sys.platform,own_gil_interpreters=2,
                   yaml_libyaml=False,debugpy_check='import/version only; no debugger session',
                   native_completed=True),f,indent=2)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python', type=Path, required=True)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--vendor', type=Path)
    parser.add_argument('--native', action='store_true', help='Probe the Windows cp312 native wheels')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    reports = []
    if args.vendor:
        report = args.output / 'pure-own-gil.json'
        subprocess.run([str(args.python), '-I', '-S', '-B', '-c', PURE_SCRIPT,
                        str(args.vendor.resolve()), str(report.resolve())], check=True, timeout=20)
        reports.append(json.loads(report.read_text(encoding='utf-8')))
    if args.native:
        lock = read_lock()
        for package in lock['packages']:
            artifact = lock['artifacts'][package['host_probe_artifact']]
            wheel = fetch(artifact, args.cache)
            with tempfile.TemporaryDirectory(prefix=package['name'] + '-', dir=args.output) as temporary:
                unpack_zip(wheel, temporary)
                for mode in ('main', 'own-gil'):
                    report = args.output / (package['name'] + '-' + mode + '.json')
                    subprocess.run([str(args.python), '-I', '-S', '-B', '-c', NATIVE_SCRIPT,
                                    str(Path(temporary).resolve()), package['name'], package['probe_import'], mode,
                                    str(report.resolve())], check=True, timeout=20)
                    data = json.loads(report.read_text(encoding='utf-8'))
                    data.update(artifact_sha256=digest(wheel), artifact=artifact['filename'])
                    write_json(report, data)
                    reports.append(data)
    if not reports:
        parser.error('Select --vendor and/or --native')
    write_json(args.output / 'import-probes.json', {'reports': reports, 'timeout_seconds': 20})
    print(json.dumps(reports, indent=2))


if __name__ == '__main__':
    main()
