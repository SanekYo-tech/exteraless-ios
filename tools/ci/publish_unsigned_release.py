"""Stage a verified unsigned IPA release from a nested or flat artifact download.

upload-artifact keeps absolute paths outside the workspace, so a successful
upload can extract as Shared/telegram-ios/build/artifacts/* rather than as
files at the artifact root. This locator accepts either layout. It does not
sign, rebuild, or treat a package check as a device-launch result.
"""

from pathlib import Path
import argparse
import hashlib
import json
import textwrap
import zipfile


REQUIRED = ('Telegram.DSYMs.zip', 'runtime-manifest.json', 'Telegram_dossier.zip')


def locate(root, name):
    matches = [path for path in Path(root).rglob(name) if path.is_file()]
    if len(matches) != 1:
        raise SystemExit(name + ' not found once: ' + repr([str(path) for path in matches]))
    return matches[0]


def verify(root, version, build_number):
    root = Path(root)
    ipa = locate(root, 'Telegram.ipa')
    manifest = json.loads(locate(root, 'build-manifest.json').read_text(encoding='utf-8'))
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    expected = {'version': version, 'build_number': str(build_number), 'sha256': digest}
    for key, value in expected.items():
        if str(manifest.get(key)) != value:
            raise SystemExit('Release artifact {} mismatch: {!r} != {!r}'.format(key, manifest.get(key), value))
    if not str(manifest.get('signing', '')).startswith('unsigned'):
        raise SystemExit('Refusing to publish an artifact that is not unsigned')
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None or any(name.endswith('.mobileprovision') for name in archive.namelist()):
            raise SystemExit('IPA failed ZIP/profile check before release')
    for name in REQUIRED:
        locate(root, name)
    entitlements = [path for path in root.rglob('*.entitlements') if path.is_file()]
    if not entitlements:
        raise SystemExit('Missing entitlement templates')
    return {'ipa': ipa, 'manifest': manifest, 'digest': digest, 'entitlements': entitlements, 'root': root}


def notes_for(version, build_number, commit):
    return textwrap.dedent('''\
    Unsigned IPA exteraless iOS {version} ({build}).

    Подписывается своим сертификатом. Bundle ID не менять: `ph.telegra.Telegraph`.
    В профиле и entitlements нужен App Group `group.ph.telegra.Telegraph`.
    Шаблоны прав лежат в `signing-entitlements.zip`.

    Относительно build 41: отказ App Group, ошибка записи контейнера и ошибка Client API
    показываются после подключения окна к сцене, а не остаются пустым экраном.
    Подтверждённый API-alert не повторяется после успешной перезагрузки settings.

    Это не доказательство причины чёрного экрана на конкретном устройстве и не приёмка
    434 native tests, 20 сцен и кадрового ревью. До публикации проверены unsigned Mach-O,
    resources, entitlement templates и SHA-256 этого же артефакта.

    Commit: {commit}
    ''').format(version=version, build=build_number, commit=commit)


def stage(root, version, build_number, commit, destination, notes_path):
    found = verify(root, version, build_number)
    destination = Path(destination)
    destination.mkdir(parents=True)
    ipa_name = 'exteraless-ios-{}-{}.ipa'.format(version, build_number)
    staged = {
        'ipa': destination / ipa_name,
        'dsyms': destination / 'Telegram.DSYMs.zip',
        'manifest': destination / 'build-manifest.json',
        'runtime': destination / 'runtime-manifest.json',
        'dossier': destination / 'Telegram_dossier.zip',
        'entitlements': destination / 'signing-entitlements.zip',
    }
    for key, source_name in (('dsyms', 'Telegram.DSYMs.zip'), ('manifest', 'build-manifest.json'),
                             ('runtime', 'runtime-manifest.json'), ('dossier', 'Telegram_dossier.zip')):
        staged[key].write_bytes(locate(found['root'], source_name).read_bytes())
    staged['ipa'].write_bytes(found['ipa'].read_bytes())
    with zipfile.ZipFile(staged['entitlements'], 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(found['entitlements']):
            archive.write(path, path.name)
    Path(notes_path).write_text(notes_for(version, build_number, commit), encoding='utf-8')
    return {'digest': found['digest'], 'files': [str(path) for path in staged.values()]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assets', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build-number', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--stage', type=Path, required=True)
    parser.add_argument('--notes', type=Path, required=True)
    args = parser.parse_args()
    result = stage(args.assets, args.version, args.build_number, args.commit, args.stage, args.notes)
    print('Release identity verified', args.version, args.build_number, result['digest'])


if __name__ == '__main__':
    main()
