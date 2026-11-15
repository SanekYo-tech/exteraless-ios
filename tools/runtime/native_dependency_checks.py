"""Tiny real operations run inside the native component probe's interpreters."""

import importlib
import io
import json


def check(package, modules):
    try:
        loaded = {name: importlib.import_module(name).__file__ for name in modules}
        if package == 'pillow':
            from PIL import Image
            stream = io.BytesIO()
            Image.new('RGB', (3, 2), (12, 34, 56)).save(stream, format='PNG')
            stream.seek(0)
            with Image.open(stream) as image:
                assert image.size == (3, 2) and image.getpixel((1, 1)) == (12, 34, 56)
        elif package == 'lxml':
            from lxml import etree, objectify
            root = etree.fromstring(b'<root><value>native</value></root>')
            assert root.xpath('string(value)') == 'native'
            assert etree.tostring(root) == b'<root><value>native</value></root>'
            assert str(objectify.fromstring(b'<root><value>2</value></root>').value) == '2'
        else:
            raise ValueError('Unknown native fixture package')
        result = {'ok': True, 'modules': loaded}
    except BaseException as error:
        result = {'ok': False, 'error_type': type(error).__name__, 'error': str(error)}
    return json.dumps(result)
