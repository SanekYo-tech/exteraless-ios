"""Finite SDK followup inputs; no source edits or Root pin regeneration."""

import ast
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SDK_PYTESTS = (
    'tools/compat/tests/test_sdk_core_counterexamples.py',
    'tools/compat/tests/test_sdk_direct_hooks.py',
    'tools/compat/tests/test_sdk_manager_custom_alias.py',
    'tools/compat/tests/test_ios_elyx_archives.py',
    'tools/compat/tests/test_sdk_developer_proxy.py',
    'tools/compat/tests/test_ios_elyx_p1.py',
    'tools/compat/tests/test_native_elyx_developer.py',
)
DEVELOPER_NATIVE_TEST = 'tools/compat/tests/test_sdk_developer_native.py'
NATIVE_CANDIDATE_TEST = 'tools/compat/tests/test_native_elyx_candidate.py'
NATIVE_FILES_TEST = 'tools/compat/tests/test_native_elyx_files.py'
NATIVE_INGRESS_TEST = 'tools/compat/tests/test_native_elyx_ingress.py'
NATIVE_READINESS_TEST = 'tools/compat/tests/test_native_elyx_readiness.py'
NATIVE_MODE_TEST = 'tools/compat/tests/test_native_elyx_mode_aba.py'
NATIVE_DEVELOPER_TESTS = (NATIVE_FILES_TEST, NATIVE_INGRESS_TEST, NATIVE_READINESS_TEST, NATIVE_MODE_TEST)
NATIVE_CANDIDATE_INPUTS = (
    'tools/compat/tests/fixtures/native_elyx/Package.swift',
    'tools/compat/tests/fixtures/native_elyx/CandidateProbe.swift',
    'tools/compat/tests/test_native_elyx_developer.py',
    'tools/compat/tests/test_ios_elyx_archives.py',
)
SWIFTPM_FOLLOWUP_TESTS = (
    'swift/PluginHost/Tests/PluginHostTests/PluginSendHookPriorityTests.swift',
    'swift/PluginHost/Tests/PluginHostTests/PluginSettingsPageLeaseTests.swift',
    'swift/PluginHost/Tests/PluginHostTests/PluginTrustHostTests.swift',
    'swift/PluginHost/Tests/PluginHostTests/PluginTrustLevelTests.swift',
    'swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperTests.swift',
    'swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperFilesTests.swift',
    'swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperActivationTests.swift',
    'swift/PluginHost/Tests/PluginHostTests/PluginResourcePathTests.swift',
    'swift/ExteralessCore/Tests/ExteralessCoreTests/ClientSettingsSearchTests.swift',
    'swift/ExteralessCore/Tests/ExteralessCoreTests/ToolsArchiveIDCodecTests.swift',
    'swift/ExteralessCore/Tests/ExteralessCoreTests/CoreSettingsResetTests.swift',
)


def developer_native_sources():
    """Read the listener test's actual compiler list, including its Swift main."""
    tree = ast.parse((ROOT / DEVELOPER_NATIVE_TEST).read_text(encoding='utf-8'))
    worker = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'worker')
    assignment = next(node for node in worker.body if isinstance(node, ast.Assign)
                      and any(isinstance(target, ast.Name) and target.id == 'sources' for target in node.targets))
    if not isinstance(assignment.value, ast.ListComp):
        raise ValueError('Review changed native developer compiler declaration')
    names = ast.literal_eval(assignment.value.generators[0].iter)
    ui = ROOT / 'telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI'
    result = [ui / name for name in names]
    additions = [node.value.args[0] for node in worker.body if isinstance(node, ast.Expr)
                 and isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Attribute)
                 and isinstance(node.value.func.value, ast.Name) and node.value.func.value.id == 'sources'
                 and node.value.func.attr == 'append']
    if len(additions) != 1 or not isinstance(additions[0], ast.BinOp) or not isinstance(additions[0].op, ast.Div):
        raise ValueError('Review changed native developer Swift fixture declaration')
    relative = ast.literal_eval(additions[0].right)
    if not relative.startswith('fixtures/') or '..' in Path(relative).parts:
        raise ValueError('Native developer fixture must remain an owned source')
    result.append((ROOT / DEVELOPER_NATIVE_TEST).parent / relative)
    return result


def host_compile_inputs(*, tests):
    """Actual local SwiftPM package roots used by the bounded native selectors."""
    package = ROOT / 'swift/PluginHost'
    folders = ('Sources', 'Tests') if tests else ('Sources',)
    files = [package / 'Package.swift']
    for folder in folders:
        files.extend(path for path in sorted((package / folder).rglob('*'))
                     if path.is_file() and not any(part.startswith('.') for part in path.relative_to(package).parts))
    return files


def ingress_native_sources():
    """Read the frozen ingress fixture's actual copied compile-source declaration."""
    tree = ast.parse((ROOT / NATIVE_INGRESS_TEST).read_text(encoding='utf-8'))
    values = {target.id: node.value for node in tree.body if isinstance(node, ast.Assign)
              for target in node.targets if isinstance(target, ast.Name)}
    declared = values['INPUTS']
    if not isinstance(declared, ast.ListComp):
        raise ValueError('Review changed ingress compiler-source declaration')
    ui = ROOT / 'telegram-ios/submodules/TelegramUI'
    sources = [ui / 'Sources/ExteralessClient/PluginUI' / name
               for name in ast.literal_eval(declared.generators[0].iter)]
    test = values['TEST']
    if not isinstance(test, ast.BinOp) or not isinstance(test.op, ast.Div):
        raise ValueError('Review changed ingress XCTest source declaration')
    sources.append(ui / ast.literal_eval(test.right))
    return sources


def mode_aba_native_sources():
    """Actual copied inputs and exact Root/queue spans of the native mode fixture."""
    tree = ast.parse((ROOT / NATIVE_MODE_TEST).read_text(encoding='utf-8'))
    values = {target.id: node.value for node in tree.body if isinstance(node, ast.Assign)
              for target in node.targets if isinstance(target, ast.Name)}
    declared = values['SOURCES']
    if not (isinstance(declared, ast.Call) and isinstance(declared.func, ast.Name)
            and declared.func.id == 'tuple' and len(declared.args) == 1
            and isinstance(declared.args[0], ast.GeneratorExp)):
        raise ValueError('Review changed mode-ABA compiler-source declaration')
    names = ast.literal_eval(declared.args[0].generators[0].iter)
    if not all(isinstance(name, str) and Path(name).name == name for name in names):
        raise ValueError('Mode-ABA compiler inputs must be named owned sources')
    ui = ROOT / 'telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI'
    return [ui / name for name in names] + [ROOT / name for name in (
        'telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift',
        'swift/ExteralessCore/Sources/ExteralessCore/ExteraConfigCompatibility.swift',
        'swift/PluginHost/Tests/PluginHostTests/HostLifecycleTestSupport.swift',
        'tools/compat/tests/fixtures/native_elyx_mode/RootFixture.swift',
        'tools/compat/tests/fixtures/native_elyx_mode/ModeABATests.swift',
    )]
