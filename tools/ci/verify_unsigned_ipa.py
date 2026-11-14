"""Check the actual IPA produced by Bazel, using bounded reads.

An unsigned hand-off may contain linker-generated ad-hoc Mach-O signatures.
It must not contain developer signatures or provisioning profiles. Validation
does not sign, extract, launch, or modify the app.
"""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import zipfile


EXTENSIONS = (
    'ShareExtension', 'NotificationContentExtension',
    'NotificationServiceExtensionv1', 'IntentsExtension',
    'WidgetExtension', 'BroadcastUploadExtension',
)
FRAMEWORKS = ('MtProtoKitFramework', 'SwiftSignalKitFramework', 'PostboxFramework',
              'TelegramCoreFramework', 'TelegramUIFramework')


def inspect_executable(archive, path):
    entry = archive.getinfo(path)
    with archive.open(entry) as stream:
        prefix = stream.read(8)
        fat_formats = {
            b'\xca\xfe\xba\xbe': ('>', 20), b'\xbe\xba\xfe\xca': ('<', 20),
            b'\xca\xfe\xba\xbf': ('>', 32), b'\xbf\xba\xfe\xca': ('<', 32),
        }
        if prefix[:4] not in fat_formats:
            return {'path': path, **_inspect_slice(stream, path, 0, entry.file_size)}
        if len(prefix) != 8:
            raise ValueError('Truncated fat Mach-O header: {}'.format(path))
        endian, record_size = fat_formats[prefix[:4]]
        count = struct.unpack(endian + 'I', prefix[4:])[0]
        if not 1 <= count <= 16:
            raise ValueError('Invalid fat Mach-O slice count: {}'.format(path))
        records = stream.read(record_size * count)
        if len(records) != record_size * count:
            raise ValueError('Truncated fat Mach-O header: {}'.format(path))
        slices = []
        for index in range(count):
            fields = struct.unpack_from(endian + ('5I' if record_size == 20 else 'IIQQII'), records, index * record_size)
            cpu, _, offset, length = fields[:4]
            if cpu != 0x0100000C or offset < 8 + len(records) or offset + length > entry.file_size:
                raise ValueError('Invalid/non-arm64 fat Mach-O slice: {}'.format(path))
            slices.append(_inspect_slice(stream, path, offset, length))
        return {'path': path, 'platform': 2, 'architecture': 'arm64',
                'signing': 'ad-hoc' if any(s['signing'] == 'ad-hoc' for s in slices) else 'none',
                'slices': slices}


def _inspect_slice(stream, path, slice_offset, slice_size):
    stream.seek(slice_offset)
    header = stream.read(32)
    if slice_size < 32 or len(header) != 32 or header[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('{} is not a 64-bit Mach-O'.format(path))
    _, cpu, _, _, count, size, _, _ = struct.unpack('<8I', header)
    if cpu != 0x0100000C or size > 1024 * 1024 or count > size // 8:
        raise ValueError('{} has an unexpected architecture/load-command header'.format(path))
    commands = stream.read(size)
    if len(commands) != size or size > slice_size - 32:
        raise ValueError('Truncated Mach-O load commands: {}'.format(path))
    offset, platform, signature = 0, None, None
    for _ in range(count):
        if offset + 8 > size:
            raise ValueError('Truncated Mach-O command: {}'.format(path))
        command, length = struct.unpack_from('<II', commands, offset)
        if length < 8 or offset + length > size:
            raise ValueError('Invalid Mach-O command size: {}'.format(path))
        if command == 0x32 and length >= 24:  # LC_BUILD_VERSION
            platform = struct.unpack_from('<I', commands, offset + 8)[0]
        elif command == 0x25 and length >= 16 and platform is None:
            platform = 2  # LC_VERSION_MIN_IPHONEOS
        elif command == 0x1D and length >= 16:  # LC_CODE_SIGNATURE
            signature = struct.unpack_from('<II', commands, offset + 8)
        offset += length
    if platform != 2:
        raise ValueError('{} is not a device iOS binary (platform {})'.format(path, platform))
    signing = 'none'
    if signature is not None:
        data_offset, data_size = signature
        if data_size < 12 or data_size > 16 * 1024 * 1024 or data_offset + data_size > slice_size:
            raise ValueError('Invalid Mach-O signature bounds: {}'.format(path))
        stream.seek(slice_offset + data_offset)
        blob = stream.read(data_size)
        magic, length, slots = struct.unpack_from('>III', blob)
        if magic != 0xFADE0CC0 or length > len(blob) or 12 + 8 * slots > length:
            raise ValueError('Invalid code-signature superblob: {}'.format(path))
        directories = 0
        for index in range(slots):
            kind, start = struct.unpack_from('>II', blob, 12 + index * 8)
            if start + 8 > length:
                raise ValueError('Truncated signature slot: {}'.format(path))
            _, slot_size = struct.unpack_from('>II', blob, start)
            if slot_size < 8 or start + slot_size > length:
                raise ValueError('Invalid signature slot size: {}'.format(path))
            if kind == 0x10000 and slot_size > 8:  # CMS signer blob
                raise ValueError('Developer/CMS signature in unsigned artifact: {}'.format(path))
            if kind == 0 or 0x1000 <= kind <= 0x1005:
                if slot_size < 16:
                    raise ValueError('Truncated code directory: {}'.format(path))
                flags = struct.unpack_from('>I', blob, start + 12)[0]
                if not flags & 2:  # CS_ADHOC
                    raise ValueError('Non-ad-hoc signature in unsigned artifact: {}'.format(path))
                directories += 1
        if not directories:
            raise ValueError('Signature has no code directory: {}'.format(path))
        signing = 'ad-hoc'
    return {'platform': platform, 'architecture': 'arm64', 'signing': signing}


def verify_ipa(path, configuration, version, build_number):
    path = Path(path)
    bundles, embedded_binaries = [], []
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError('IPA has duplicate archive entries')
        if any(name.endswith('.mobileprovision') for name in names):
            raise ValueError('Unsigned IPA contains a provisioning profile')
        if any('/_CodeSignature/' in name for name in names):
            raise ValueError('Unsigned IPA contains a bundle resource signature')
        root = 'Payload/Telegram.app'
        expected = [root] + ['{}/PlugIns/{}.appex'.format(root, name) for name in EXTENSIONS]
        for bundle in expected:
            try:
                info = plistlib.loads(archive.read(bundle + '/Info.plist'))
            except KeyError as exc:
                raise ValueError('Missing app/extension in IPA: {}'.format(bundle)) from exc
            bundle_id = info.get('CFBundleIdentifier', '')
            if bundle == root:
                if bundle_id != configuration['bundle_id']:
                    raise ValueError('IPA bundle ID does not match the build configuration')
            elif not bundle_id.startswith(configuration['bundle_id'] + '.'):
                raise ValueError('Extension bundle ID does not match its app: {}'.format(bundle_id))
            if str(info.get('CFBundleVersion')) != str(build_number) or str(info.get('CFBundleShortVersionString')) != version:
                raise ValueError('Stale or mismatched app/extension version: {}'.format(bundle))
            executable = info.get('CFBundleExecutable')
            if not executable or '/' in executable or '\\' in executable:
                raise ValueError('Invalid CFBundleExecutable in {}'.format(bundle))
            binary = inspect_executable(archive, bundle + '/' + executable)
            bundles.append({'bundle_id': bundle_id, **binary})
        # The host bundles five source-built frameworks. Check them and any
        # additional frameworks/dylibs, rather than only the app entry points.
        framework_plists = sorted(name for name in names if name.endswith('.framework/Info.plist'))
        required_frameworks = {'{}/Frameworks/{}.framework/Info.plist'.format(root, name) for name in FRAMEWORKS}
        if not required_frameworks.issubset(framework_plists):
            raise ValueError('Missing a required Telegram framework in the IPA')
        for info_path in framework_plists:
            info = plistlib.loads(archive.read(info_path))
            executable = info.get('CFBundleExecutable')
            if not executable or '/' in executable or '\\' in executable:
                raise ValueError('Invalid framework executable in {}'.format(info_path))
            embedded_binaries.append(inspect_executable(archive, info_path.rsplit('/', 1)[0] + '/' + executable))
        for name in names:
            if name.endswith('.dylib'):
                embedded_binaries.append(inspect_executable(archive, name))
        bad_entry = archive.testzip()  # streams CRC checks; does not extract the bundle
        if bad_entry:
            raise ValueError('Corrupt ZIP entry: {}'.format(bad_entry))
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return {
        'signing': 'unsigned (linker ad-hoc signatures allowed)',
        'version': version, 'build_number': str(build_number),
        'bytes': path.stat().st_size, 'sha256': digest.hexdigest(), 'bundles': bundles,
        'embedded_binaries': embedded_binaries,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--configuration', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build-number', required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    report = verify_ipa(
        args.ipa, json.loads(args.configuration.read_text(encoding='utf-8')),
        args.version, args.build_number
    )
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print('Unsigned IPA verified: app + {} extensions, SHA-256 {}'.format(len(report['bundles']) - 1, report['sha256']))


if __name__ == '__main__':
    main()
