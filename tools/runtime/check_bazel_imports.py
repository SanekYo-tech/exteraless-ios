"""Bounded Swift import -> actual owning BUILD dependency audit.

This parses declarations, not Bazel configurations. Only explicit module/label
contracts are checked; it never guesses a dependency from a similarly named path.
Unsupported/computed source ownership is reported for review rather than patched.
"""

import argparse
import ast
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
MODULE_LABELS = {
    'ExteralessCore': '//third-party/exteraless:ExteralessCore',
    'PluginHost': '//third-party/exteraless:PluginHost',
    'PluginHooks': '//third-party/exteraless:PluginHooks',
    'LocalizedPeerData': '//submodules/LocalizedPeerData:LocalizedPeerData',
    'Svg': '//submodules/Svg:Svg',
    'ComponentFlow': '//submodules/ComponentFlow:ComponentFlow',
    'Weather': '//submodules/Weather:Weather',
    'Emoji': '//submodules/Emoji:Emoji',
    'ChatMessageItemImpl': '//submodules/TelegramUI/Components/Chat/ChatMessageItemImpl:ChatMessageItemImpl',
    'ChatMessageItemView': '//submodules/TelegramUI/Components/Chat/ChatMessageItemView:ChatMessageItemView',
    'QuickReactionSetupController': '//submodules/TelegramUI/Components/Settings/QuickReactionSetupController:QuickReactionSetupController',
    'sqlcipher': '//submodules/sqlcipher:sqlcipher',
}
IMPORT = re.compile(r'^\s*(?:@(?:testable|preconcurrency|_exported|_implementationOnly)\s+)?'
                    r'(?:(?:public|internal|private|fileprivate)\s+)?import\s+'
                    r'(?:(?:class|struct|enum|protocol|typealias|func|let|var)\s+)?([A-Za-z_]\w*)', re.M)


def strings(value):
    return [item.value for item in ast.walk(value) if isinstance(item, ast.Constant) and isinstance(item.value, str)]


def glob_regex(pattern):
    output, index = '^', 0
    while index < len(pattern):
        if pattern[index:index + 3] == '**/':
            output += '(?:.*/)?'; index += 3
        elif pattern[index:index + 2] == '**':
            output += '.*'; index += 2
        elif pattern[index] == '*':
            output += '[^/]*'; index += 1
        elif pattern[index] == '?':
            output += '[^/]'; index += 1
        else:
            output += re.escape(pattern[index]); index += 1
    return re.compile(output + '$')


def source_matches(value, relative, groups, seen=()):
    if isinstance(value, (ast.List, ast.Tuple)):
        return any(source_matches(item, relative, groups, seen) for item in value.elts)
    if isinstance(value, ast.Constant) and isinstance(value.value, str):
        name = value.value
        if name.startswith(':') and name[1:] in groups and name not in seen:
            return source_matches(groups[name[1:]], relative, groups, (*seen, name))
        return name == relative
    if isinstance(value, ast.BinOp) and isinstance(value.op, ast.Add):
        return source_matches(value.left, relative, groups, seen) or source_matches(value.right, relative, groups, seen)
    if isinstance(value, ast.Call) and isinstance(value.func, ast.Name) and value.func.id == 'glob' and value.args:
        includes = strings(value.args[0])
        excluded = [pattern for item in value.keywords if item.arg == 'exclude' for pattern in strings(item.value)]
        return any(glob_regex(item).match(relative) for item in includes) and not any(glob_regex(item).match(relative) for item in excluded)
    return False


def normalized_label(label):
    if label.startswith('//') and ':' not in label:
        return label + ':' + label.rsplit('/', 1)[-1]
    return label


def declarations(path):
    tree = ast.parse(path.read_text(encoding='utf-8'), filename=str(path))
    rules, groups = [], {}
    for node in tree.body:
        if not isinstance(node, ast.Expr) or not isinstance(node.value, ast.Call):
            continue
        call = node.value
        if not isinstance(call.func, ast.Name) or call.func.id not in ('swift_library', 'filegroup'):
            continue
        args = {arg.arg: arg.value for arg in call.keywords}
        name = args.get('name')
        if not isinstance(name, ast.Constant) or not isinstance(name.value, str):
            continue
        if call.func.id == 'filegroup' and 'srcs' in args:
            groups[name.value] = args['srcs']
        elif 'srcs' in args:
            rules.append((name.value, args))
    return rules, groups


def audit(telegram_root, modules, *, paths=None):
    telegram_root = Path(telegram_root).resolve()
    paths = paths if paths is not None else telegram_root.rglob('*.swift')
    cache, checks, unresolved = {}, [], []
    file_count, bytes_read = 0, 0
    for source in paths:
        source = Path(source).resolve()
        if any(part.startswith('.') or part.startswith('bazel-') for part in source.relative_to(telegram_root).parts):
            continue
        file_count += 1
        if file_count > 60000:
            raise ValueError('Import audit exceeded its file bound')
        with source.open('r', encoding='utf-8', errors='replace') as stream:
            text = stream.read(65536)
        bytes_read += len(text)
        if bytes_read > 384 * 1024 * 1024:
            raise ValueError('Import audit exceeded its read bound')
        imports = [match for match in IMPORT.finditer(text) if match[1] in modules]
        if not imports:
            continue
        parent = source.parent
        while parent != telegram_root and not any((parent / name).is_file() for name in ('BUILD.bazel', 'BUILD')):
            parent = parent.parent
        build = next((parent / name for name in ('BUILD.bazel', 'BUILD') if (parent / name).is_file()), None)
        if build is None:
            unresolved.append({'source': source.relative_to(telegram_root).as_posix(), 'reason': 'no owning BUILD'})
            continue
        if build not in cache:
            cache[build] = declarations(build)
        rules, groups = cache[build]
        relative = source.relative_to(parent).as_posix()
        owners = [(name, args) for name, args in rules if source_matches(args['srcs'], relative, groups)]
        if not owners:
            unresolved.append({'source': source.relative_to(telegram_root).as_posix(), 'reason': 'not in an explicit swift_library srcs declaration'})
        for owner, args in owners:
            deps = {normalized_label(item) for item in strings(args['deps'])} if 'deps' in args else set()
            for match in imports:
                checks.append({'source': source.relative_to(telegram_root).as_posix(),
                               'line': text[:match.start()].count('\n') + 1, 'module': match[1],
                               'build': build.relative_to(telegram_root).as_posix(), 'target': owner,
                               'required_label': MODULE_LABELS[match[1]],
                               'declared': MODULE_LABELS[match[1]] in deps})
    return {'kind': 'declaration-audit (not Bazel analysis)', 'checked_files': file_count,
            'checked_imports': len(checks), 'missing': [item for item in checks if not item['declared']],
            'unresolved_ownership': unresolved,
            'targets': sorted({item['build'] + ':' + item['target'] for item in checks})}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--telegram-root', type=Path, default=ROOT / 'telegram-ios')
    parser.add_argument('--module', action='append', choices=sorted(MODULE_LABELS))
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    report = audit(args.telegram_root, args.module or ['ExteralessCore', 'PluginHost', 'PluginHooks'])
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))
    return 1 if report['missing'] or report['unresolved_ownership'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
