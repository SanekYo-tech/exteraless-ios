"""Explicit Reset, secondary-permission and Map recordings after the base eight."""

import math
import re
import uuid
from client_ui_harness_map import MAP_SCENARIOS, MAP_BATCH, check_map_sources

RESET_SCENARIOS = (
    'reset-ready-cancelled', 'reset-prepare-before-return', 'reset-prepare-after-return',
    'reset-reply-before-return', 'reset-reply-after-return', 'reset-prepare-actual-pop',
    'reset-reply-actual-pop', 'reset-retired-ready', 'reset-retired-prepare', 'reset-retired-reply',
)
TRUST_SCENARIOS = ('trust-secondary-permissions',)
SUPPLEMENT_SCENARIOS = RESET_SCENARIOS + TRUST_SCENARIOS + MAP_SCENARIOS
SUPPLEMENT_BATCHES = (
    ('reset-1', 'reset-1-3', RESET_SCENARIOS[:3]),
    ('reset-2', 'reset-2-3', RESET_SCENARIOS[3:6]),
    ('reset-3', 'reset-3-3', RESET_SCENARIOS[6:9]),
    ('reset-4', 'reset-4-1', RESET_SCENARIOS[9:]),
    ('trust-secondary', 'trust-secondary-1', TRUST_SCENARIOS),
    MAP_BATCH,
)
RESET_DARK = {'reset-prepare-before-return', 'reset-reply-before-return', 'reset-prepare-actual-pop',
              'reset-retired-ready', 'reset-retired-reply'}
RESET_SOURCES = (
    'telegram-ios/Tests/Exteraless/SettingsResetNavigationChecks.swift',
    'telegram-ios/Tests/ExteralessHarness/BUILD', 'telegram-ios/Tests/ExteralessHarness/Info.plist',
    'telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessScenario.swift',
    'telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessScenarios.swift',
    'telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/SettingsResetController.swift',
    'telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/SettingsResetIntegration.swift',
    'telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsUIHelpers.swift',
    'telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsController.swift',
    'telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift',
    'swift/ExteralessCore/Sources/ExteralessCore/CoreSettingsResetCatalog.swift',
    'swift/ExteralessCore/Sources/ExteralessCore/CoreSettingsResetOperation.swift',
    'swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift',
    'swift/ExteralessCore/Sources/ExteralessCore/ClientSettingDefinition.swift',
    'swift/ExteralessCore/Sources/ExteralessCore/ClientSettingValue.swift',
    'swift/ExteralessCore/Sources/ExteralessCore/ClientSettingsSourceRoutes.swift',
    'swift/ExteralessCore/Sources/ExteralessCore/ToolsFeatures.swift',
    'swift/ExteralessCore/Sources/ExteralessCore/PrivacyFeatures.swift',
    'telegram-ios/submodules/Display/Source/Navigation/NavigationContainer.swift',
    'telegram-ios/submodules/Display/Source/NavigationTransitionCoordinator.swift',
    'telegram-ios/submodules/Display/Source/NavigationTransitionSpring.swift',
    'telegram-ios/submodules/Display/Source/NavigationInteractivePopTracker.swift',
)
TRUST_SOURCES = (
    'telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessTrustSecondary.swift',
    'telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/Tests/PluginTrustSecondaryUIFixture.swift',
    'telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIBridgeExtension.swift',
    'telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIContentController.swift',
    'telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUILifecycle.swift',
)


def require(value, message):
    if not value:
        raise ValueError(message)


def check_sources(manifest, scenarios):
    required = set()
    if set(scenarios) & set(RESET_SCENARIOS):
        required.update(RESET_SOURCES)
        required.add('telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessResetSupplement.swift')
    if set(scenarios) & set(TRUST_SCENARIOS):
        required.update(TRUST_SOURCES)
    files = manifest.get('files', {})
    require(required <= files.keys(), 'Supplement is missing actual fixture/provider source inputs')
    if set(scenarios) & set(MAP_SCENARIOS):
        check_map_sources(manifest)


def reset_probes(scenario):
    require(scenario in RESET_SCENARIOS, 'Unknown reset witness')
    before = scenario in ('reset-prepare-before-return', 'reset-reply-before-return')
    retired = 'actual-pop' in scenario or scenario.startswith('reset-retired-')
    return (['home', 'reset-before-swipe', 'reset-dragging']
            + (['reset-old-reply-before-return'] if before else [])
            + ['reset-navigation-ended', 'reset-retired-idle' if retired else 'reset-returned-ready', 'reset-cleanup'])


def validate_reset(state, scenario):
    from client_ui_harness_domains import check_manifest
    from client_ui_harness_visuals import artifact_entries
    probes = state.get('probes', [])
    require([probe.get('name') for probe in probes] == reset_probes(scenario), 'Missing/reordered reset navigation witnesses')
    manifest = check_manifest(state.get('facts', {}).get('domainSources', {}))
    check_sources(manifest, (scenario,))
    require(state.get('pythonRequested') is False, 'Reset supplement must not execute Python plugins')
    final = state.get('facts', {}).get('resetSupplement', {})
    require(final.get('completed') is True and final.get('scenario') == scenario
            and final.get('fixture') == 'SettingsResetNavigationChecks'
            and final.get('interactionDeadlineSeconds') == 18 and final.get('replyGateSeconds') == 6,
            'The actual bounded reset fixture did not complete')
    require(final.get('palette') == ('dark' if scenario in RESET_DARK else 'light'), 'Reset palette identity differs')
    images = {entry['path'] for entry in artifact_entries(state)}
    values = {probe['name']: probe['semantic'] for probe in probes[1:]}
    for probe in probes[1:]:
        value = probe['semantic']
        require(value.get('nativeViewImage') in images, 'Reset witness lacks its real native view capture')
        require(probe.get('dark') is (scenario in RESET_DARK), 'Reset witness has the wrong palette')
        if probe['name'] == 'reset-cleanup':
            require(value.get('nativeFixtureReturned') is True and value.get('firstResponder') is False, 'Reset cleanup did not return cleanly')
            continue
        require(value.get('scenario') == scenario, 'Reset witness came from another case')
        uuid.UUID(value.get('authorityID', ''))
        for key in ('planID', 'sessionPlanID'):
            if value.get(key) != 'none': uuid.UUID(value.get(key, ''))
        for key in ('prepareReplies', 'resetReplies', 'removals'):
            require(type(value.get(key)) is int and value[key] >= 0, 'Missing real reset provider/lifecycle counters')
        frame = value.get('pageFrame', [])
        require(len(frame) == 4 and all(type(v) in (int, float) and math.isfinite(v) for v in frame), 'Invalid reset page frame')
    first, dragging, ended = (values[name] for name in ('reset-before-swipe', 'reset-dragging', 'reset-navigation-ended'))
    require(first.get('sources') == {name: manifest['files'][name] for name in RESET_SOURCES}, 'Reset 22-source receipt differs from the compiled manifest')
    require(first.get('lifecycle') == ['willAppear', 'didAppear'] and first['prepareReplies'] == 1, 'Reset initial provider/lifecycle sequence differs')
    require(dragging.get('lifecycle') == ['willDisappear'] and dragging.get('authorityValid') is False, 'Real interactive-pop departure was not observed')
    actual_pop = 'actual-pop' in scenario
    retired = actual_pop or scenario.startswith('reset-retired-')
    require(ended.get('lifecycle') == ['willDisappear', 'didDisappear' if actual_pop else 'didAppear'], 'Reset must observe actual Display completion without a synthetic WillAppear')
    last = values['reset-retired-idle' if retired else 'reset-returned-ready']
    reset_count = 1 if ('reply-' in scenario or scenario == 'reset-retired-reply') else 0
    require(first['resetReplies'] == last['resetReplies'] == reset_count, 'Reset provider executed more than the selected witness')
    require(last.get('busy') is False and last.get('queuedPreview') is False, 'Reset witness retained old work or queued recovery')
    require((last.get('actualValue'), last.get('storedOverride')) == (first.get('actualValue'), first.get('storedOverride')), 'Navigation changed the stored reset state')
    if retired:
        require(last['prepareReplies'] == 1 and last.get('authorityValid') is False
                and last['removals'] == (1 if actual_pop else 0), 'Retired reset context restarted its provider')
    else:
        require(last['prepareReplies'] == 2 and last.get('authorityValid') is True and last.get('visible') is True
                and last['authorityID'] != first['authorityID'] and last.get('planID') not in ('none', first.get('planID'))
                and last.get('sessionPlanID') == 'none', 'Reset return reused an old authority/plan/session')
        action = last.get('actionFrame', [])
        require(len(action) == 4 and min(action[2:]) > 0, 'Returned native Reset cell was not mounted')
    if 'reset-old-reply-before-return' in values:
        early = values['reset-old-reply-before-return']
        require(early.get('busy') is False and early.get('visible') is False and early['prepareReplies'] == 1,
                'Old provider reply restarted work before Display returned')


def validate_trust(state, scenario):
    from client_ui_harness_domains import check_manifest
    from client_ui_harness_visuals import artifact_entries
    require(scenario in TRUST_SCENARIOS, 'Unknown trust supplement')
    check_sources(check_manifest(state.get('facts', {}).get('domainSources', {})), (scenario,))
    require(state.get('pythonRequested') is False, 'Secondary UI fixture must not claim actual Python execution')
    expected = ['home', 'trust-secondary-start', 'trust-link-visible', 'trust-external-share-visible',
                'trust-own-share-visible', 'trust-secondary-completed']
    require([probe.get('name') for probe in state.get('probes', [])] == expected, 'Secondary trust fixture did not expose all actual native surfaces')
    images = {entry['path'] for entry in artifact_entries(state)}
    for probe in state['probes'][1:]:
        require(probe.get('semantic', {}).get('nativeViewImage') in images, 'Secondary trust witness lacks a native view capture')
    final = state.get('facts', {}).get('trustSecondary', {})
    require(final.get('completed') is True and final.get('fixture') == 'PluginTrustSecondaryUIFixture.run'
            and final.get('transport') == 'canned Host worker/callbacks; real native UI consumers; no URL/network',
            'Secondary trust provider witness did not complete')
