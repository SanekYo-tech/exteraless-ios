"""Bounded declaration/source map for the dedicated native XCTest suite."""

import ast
import fnmatch
import hashlib
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'telegram-ios/build-system/Make'))
from PostboxImportCheck import strip_comments_and_strings

MAP_PATH = 'Tests/Exteraless/native-tests.json'
# Masked comments/fixture strings can leave thousands of blank lines. Leading
# \s* rescans that entire suffix at every line start; keep it horizontal so
# declaration discovery stays linear over those inputs.
CLASS = re.compile(r'^[ \t]*(?:(?:@MainActor|final|public|internal)[ \t]+)*class\s+(\w+)\s*:\s*XCTestCase\b', re.M)
METHOD = re.compile(r'^[ \t]*(?:(?:@MainActor|public|internal)[ \t]+)*func\s+(test\w+)\s*\(', re.M)
BRACE = re.compile(r'[{}]')


def fixture_classes(text, *, class_name=None):
    """Map each real XCTest class body, including multiple classes in one file.

    Reuse the existing Swift comment/string scanner; braces in fixture strings
    and methods on neighboring helper types cannot become XCTest membership.
    """
    code = strip_comments_and_strings(text)
    result = []
    for match in CLASS.finditer(code):
        if class_name is not None and match[1] != class_name:
            continue
        opening = code.find('{', match.end())
        if opening < 0:
            raise ValueError('XCTest class has no body: ' + match[1])
        depth, closing = 1, None
        for brace in BRACE.finditer(code, opening + 1):
            depth += 1 if brace[0] == '{' else -1
            if depth == 0:
                closing = brace.start()
                break
        if closing is None:
            raise ValueError('Unclosed XCTest class: ' + match[1])
        methods = []
        for method in METHOD.finditer(code, opening + 1, closing):
            prefix = code[opening + 1:method.start()]
            if prefix.count('{') == prefix.count('}'):
                methods.append(method[1])
        if not methods or len(methods) != len(set(methods)) or any(item['class'] == match[1] for item in result):
            raise ValueError('Ambiguous/empty XCTest class: ' + match[1])
        result.append({'class': match[1], 'methods': sorted(methods)})
    return result


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def label(value, package):
    if value.startswith(':'):
        return '//' + package + value
    if value.startswith('//'):
        return value if ':' in value else value + ':' + value.rsplit('/', 1)[-1]
    raise ValueError('Expected an explicit local Bazel label: ' + value)


class Declarations:
    def __init__(self, root, source_checkout=False):
        self.root = Path(root).resolve()
        self.source_checkout = source_checkout
        self.cache = {}
        self.inputs = {}
        self.paths = {}

    def input(self, path, logical=None):
        path = Path(path)
        logical = logical or path.relative_to(self.root).as_posix()
        if not path.is_file() or path.stat().st_size > 8 * 1024 * 1024:
            raise ValueError('Missing/unbounded native test input: ' + logical)
        self.inputs[logical] = digest(path)
        self.paths[logical] = path
        if len(self.inputs) > 500:
            raise ValueError('Native test declaration map exceeded its source bound')
        return path

    def rule(self, target):
        package, name = target[2:].split(':', 1)
        if package not in self.cache:
            path = self.root / package / 'BUILD'
            if not path.is_file():
                path = path.with_name('BUILD.bazel')
            self.input(path)
            rules = {}
            for node in ast.parse(path.read_text(encoding='utf-8')).body:
                if not isinstance(node, ast.Expr) or not isinstance(node.value, ast.Call):
                    continue
                call = node.value
                attributes = {item.arg: item.value for item in call.keywords}
                rule_name = attributes.get('name')
                if isinstance(call.func, ast.Name) and isinstance(rule_name, ast.Constant):
                    rules[rule_name.value] = (call.func.id, attributes)
            self.cache[package] = rules
        if name not in self.cache[package]:
            raise ValueError('Missing native test rule: ' + target)
        return package, *self.cache[package][name]

    def sources(self, value, package, seen=()):
        if isinstance(value, (ast.List, ast.Tuple)):
            return [path for item in value.elts for path in self.sources(item, package, seen)]
        if isinstance(value, ast.BinOp) and isinstance(value.op, ast.Add):
            return self.sources(value.left, package, seen) + self.sources(value.right, package, seen)
        if isinstance(value, ast.Call) and isinstance(value.func, ast.Name) and value.func.id == 'glob':
            patterns = ast.literal_eval(value.args[0])
            excludes = next((ast.literal_eval(item.value) for item in value.keywords if item.arg == 'exclude'), [])
            directory = self.root / package
            found = sorted({path for pattern in patterns for path in directory.glob(pattern) if path.is_file()
                            and not any(fnmatch.fnmatch(path.relative_to(directory).as_posix(), pattern) for pattern in excludes)})
            if not found:
                raise ValueError('Empty native test source glob in ' + package)
            return [self.input(path) for path in found]
        if isinstance(value, ast.Constant) and isinstance(value.value, str):
            name = value.value
            if name.startswith('@exteraless//'):
                external = name.removeprefix('@exteraless//').replace(':', '/', 1)
                path = self.root / 'build-input/exteraless' / external
                if self.source_checkout:
                    path = self.root.parent / external
                return [self.input(path, name)]
            if name.startswith((':', '//')):
                target = label(name, package)
                if target in seen:
                    raise ValueError('Cycle in native test source filegroups')
                child_package, kind, attributes = self.rule(target)
                if kind != 'filegroup':
                    raise ValueError('Unsupported native test source producer: ' + target)
                return self.sources(attributes['srcs'], child_package, (*seen, target))
            return [self.input(self.root / package / name)]
        raise ValueError('Unsupported native test source expression in ' + package)


def host_inputs(declarations, host, bundle_id):
    """Include the actual test app's local libraries/entry point in its identity."""
    if not host.startswith('//Tests/'):
        raise ValueError('Native test hosts must be explicit test applications: ' + host)
    _, kind, app = declarations.rule(host)
    if kind != 'ios_application' or ast.literal_eval(app['bundle_id']) != bundle_id:
        raise ValueError('Native test host bundle identity differs: ' + host)
    pending, seen = [host], set()
    while pending:
        target = pending.pop()
        if target in seen:
            continue
        seen.add(target)
        package, kind, rule = declarations.rule(target)
        if kind not in ('ios_application', 'swift_library', 'objc_library'):
            raise ValueError('Unsupported local native test host library: ' + target)
        if 'srcs' in rule:
            declarations.sources(rule['srcs'], package)
        for name in ast.literal_eval(rule.get('infoplists', ast.List(elts=[]))):
            if name.startswith(':'):
                # Generated plist contents are already fingerprinted in BUILD.
                _, producer, _ = declarations.rule(label(name, package))
                if producer != 'plist_fragment':
                    raise ValueError('Unsupported native host plist producer: ' + name)
            else:
                declarations.input(declarations.root / package / name)
        pending.extend(child for dependency in ast.literal_eval(rule.get('deps', ast.List(elts=[])))
                       if (child := label(dependency, package)).startswith('//Tests/'))


def plan_target(declarations, target, contract):
    """Resolve one handed-off cohort without regenerating the aggregate map."""
    package, kind, rule = declarations.rule(target)
    if kind != 'ios_unit_test' or 'AllTests' in target:
        raise ValueError('Unexpected target in bounded native suite: ' + target)
    host = contract.get('target_hosts', {}).get(target, {
        'label': contract['host'], 'bundle_id': contract['host_bundle_id']})
    if (label(ast.literal_eval(rule['runner']), package) != contract['runner']
            or label(ast.literal_eval(rule['test_host']), package) != host['label']):
        raise ValueError('Native target must use its declared iOS 27 runner/test host: ' + target)
    host_inputs(declarations, host['label'], host['bundle_id'])
    class_name = ast.literal_eval(rule['test_filter']) if 'test_filter' in rule else None
    # The vendored runner unions a BUILD filter with --test_filter. One exact
    # class is safe in both places; a list/wildcard would silently widen a run.
    if class_name is not None and not re.fullmatch(r'[A-Za-z_]\w*', class_name):
        raise ValueError('Bounded BUILD test_filter must name one exact XCTest class: ' + target)
    files = []
    for dependency in ast.literal_eval(rule['deps']):
        child_package, child_kind, library = declarations.rule(label(dependency, package))
        if child_kind != 'swift_library' or ast.literal_eval(library.get('testonly', ast.Constant(False))) is not True:
            raise ValueError('Native XCTest library must be testonly: ' + dependency)
        files.extend(declarations.sources(library['srcs'], child_package))
    classes = []
    for path in dict.fromkeys(files):
        if path.suffix != '.swift':
            continue
        declared = fixture_classes(path.read_text(encoding='utf-8'), class_name=class_name)
        if not declared:
            continue
        source = path.relative_to(declarations.root).as_posix()
        classes.extend(dict(item, source=source) for item in declared)
    names = [case['class'] for case in classes]
    if not classes or len(names) != len(set(names)):
        raise ValueError('Native target has no matching/unique XCTest classes: ' + target)
    return {'label': target, 'host': host['label'], 'host_bundle_id': host['bundle_id'],
            'build_test_filter': class_name, 'classes': classes}


def build_plan(telegram_root, *, source_checkout=False):
    declarations = Declarations(telegram_root, source_checkout)
    root = declarations.root
    contract = json.loads(declarations.input(root / MAP_PATH).read_text(encoding='utf-8'))
    if contract.get('schema') != 1 or contract.get('suite') != '//Tests/Exteraless:IntegrationTests':
        raise ValueError('Only the dedicated IntegrationTests suite is supported')
    if contract.get('logic_seconds') != 30 or contract.get('os_version') != '27.0' or contract.get('xcode') != '27.1':
        raise ValueError('Unexpected native test runtime/deadline contract')
    versions = json.loads(declarations.input(root / 'versions.json').read_text(encoding='utf-8'))
    if versions['xcode'] != contract['xcode']:
        raise ValueError('Native test map must match the actual app Xcode pin')
    suite_package, kind, suite = declarations.rule(contract['suite'])
    if kind != 'test_suite':
        raise ValueError('IntegrationTests must be an explicit test_suite')
    labels = [label(item, suite_package) for item in ast.literal_eval(suite['tests'])]
    if len(labels) != len(set(labels)) or not 1 <= len(labels) <= 32:
        raise ValueError('Duplicate or unbounded native test targets')
    if set(contract.get('target_hosts', {})) - set(labels):
        raise ValueError('Native test host override names a target outside the suite')
    _, _, runner = declarations.rule(contract['runner'])
    if (ast.literal_eval(runner['os_version']) != contract['os_version']
            or ast.literal_eval(runner['device_type']) != contract['device']):
        raise ValueError('Runner differs from the required available iOS 27 device')
    host_inputs(declarations, contract['host'], contract['host_bundle_id'])
    declarations.input(root / 'MODULE.bazel')
    declarations.input(root / 'build-system/exteraless-testing/BUILD')
    declarations.input(root / 'build-system/exteraless-testing/xctestrunner-serial.patch')
    declarations.input(root / 'build-system/Make/Make.py')
    declarations.input(root / 'build-system/Make/PostboxImportCheck.py')
    declarations.input(root / 'build-system/bazel-rules/rules_apple/apple/testing/default_runner/ios_test_runner.template.sh')
    targets, selected = [], {}
    for target in labels:
        resolved = plan_target(declarations, target, contract)
        for source in {case['source'] for case in resolved['classes']}:
            if source in selected:
                raise ValueError('Regression source is selected twice: ' + source)
            selected[source] = target
        targets.append(resolved)
    for source, target in contract['required_sources'].items():
        if selected.get(source) != target:
            raise ValueError('Required native regression is not owned by its selected target: ' + source)
    fingerprint = hashlib.sha256(json.dumps(declarations.inputs, sort_keys=True).encode()).hexdigest()
    return {'kind': 'source/declaration plan, not a native execution', 'contract': contract,
            'targets': targets, 'input_sha256': declarations.inputs, 'source_fingerprint': fingerprint}, declarations.paths
