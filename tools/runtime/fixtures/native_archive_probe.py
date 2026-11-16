"""Read-only observations in the real Host-owned archive interpreter.

SDKTLObservedEngine loads this observer before the unchanged Host bootstrap.
Archive loading, settings, replacement and cleanup are invoked by public Host
APIs. This module supplies no backend, loader, ZIP implementation or path bypass.
"""

import _thread
import json
import os
import sys

_owner_thread = _thread.get_ident()
_entry_calls = 0
_load_calls = 0
_metadata_calls = 0
_native_calls = 0
_neighbor_calls = 0
_sdk_calls = {}
_network = []
_problems = []
_loaded_source = None
_checks_handle = None


def _profile(frame, event, arg):
    global _entry_calls, _load_calls, _metadata_calls, _native_calls, _neighbor_calls
    try:
        if event == 'c_call':
            bridge = sys.modules.get('_exteraless_bridge')
            if bridge is not None and arg is getattr(bridge, 'xt_call_host', None):
                _native_calls += 1
            return
        if event != 'call':
            return
        path = frame.f_code.co_filename.replace('\\', '/')
        name = frame.f_code.co_name
        if path.endswith('/exteraless_runtime/__init__.py'):
            if name == 'load_json': _load_calls += 1
            if name == 'metadata_json': _metadata_calls += 1
        if path.endswith('/entry/main.py') and name == '<module>':
            _entry_calls += 1
        if path.endswith('/neighbour.py'):
            _neighbor_calls += 1
        if '/sdk/' in path and name in ('load_plugin', 'load_plugin_record', '_load_elyx_plugin',
                                        'unload_plugin', 'get_settings_json', '_serialize_setting_item'):
            key = path.split('/sdk/', 1)[1] + ':' + name
            _sdk_calls[key] = _sdk_calls.get(key, 0) + 1
    except BaseException as error:
        if len(_problems) < 8:
            _problems.append(type(error).__name__ + ': ' + str(error))


def _audit(event, arguments):
    if event in ('socket.connect', 'socket.getaddrinfo', 'socket.bind') and len(_network) < 16:
        _network.append(event)


sys.setprofile(_profile)
sys.addaudithook(_audit)


def loaded():
    global _loaded_source, _checks_handle
    import _exteraless_bridge as bridge
    import exteraless_runtime as runtime
    record = runtime._state.loader.plugins[runtime._state.plugin_id]
    _loaded_source = record.instance.on_plugin_load.__code__.co_filename
    assert _checks_handle is None and _thread.get_ident() == _owner_thread
    _checks_handle = bridge.xt_register_handle(_Checks())
    return json.dumps({'pluginId': runtime._state.plugin_id, 'handle': _checks_handle})


class _Checks:
    def snapshot(self, expected):
        import _exteraless_bridge as bridge
        import exteraless_runtime as runtime
        import elyx_runtime
        from base_plugin import PythonBridge
        from virtualjava import finder
        state = runtime._state
        assert _thread.get_ident() == _owner_thread
        assert state.loader.current_plugin_id() == state.plugin_id
        record = state.loader.plugins[state.plugin_id]
        archive = elyx_runtime.get_state(state.plugin_id)
        assert archive is not None
        seen = record.instance.get_setting('seen')
        assert seen == [expected, expected, True, None, 42, 'plain text', 'Owned title', 'asset text', state.plugin_id]
        assert record.instance.get_setting('elyx_setting') == [True, None, 7]
        assert record.module.helpers.VALUE == expected and record.module.ownlib.VALUE == expected
        cache = os.fspath(PythonBridge.getCacheDir())
        assert os.path.commonpath([cache, archive.extract_dir]) == cache
        assert record.module.__file__.startswith(archive.extract_dir + os.sep)
        assert record.instance.on_plugin_load.__code__.co_filename == record.module.__file__
        assert type(finder._State.backend) is bridge.BridgeBackend
        assert bridge.__spec__.origin == 'built-in' and _native_calls > 0
        assert _entry_calls == 1 and _load_calls == 1 and not _network and not _neighbor_calls and not _problems
        return {'pluginId': state.plugin_id, 'ownerToken': state.owner_token,
                'moduleName': record.module.__name__, 'moduleSource': record.module.__file__,
                'helperSource': record.module.helpers.__file__, 'wheelSource': record.module.ownlib.__file__,
                'archivePath': archive.archive_path, 'archiveDigest': archive.digest,
                'extractDir': archive.extract_dir, 'wheelDirs': list(archive.wheel_dirs), 'cacheDir': cache,
                'seen': seen, 'entryCalls': _entry_calls, 'nativeCalls': _native_calls,
                'networkAttempts': list(_network), 'neighborCalls': _neighbor_calls,
                'sdkCalls': dict(_sdk_calls),
                'requiredRuntimeSources': {name: sys.modules['exteraless_runtime.' + name].__file__
                                           for name in ('_archives', '_audit_paths')}}


def observation():
    bridge = sys.modules.get('_exteraless_bridge')
    runtime = sys.modules.get('exteraless_runtime')
    state = getattr(runtime, '_state', None)
    loader = sys.modules.get('extera_utils.plugin_loader')
    finder = sys.modules.get('virtualjava.finder')
    assert not _network and not _neighbor_calls and not _problems
    if state is None:
        assert _metadata_calls == 1 and _entry_calls == 0 and _load_calls == 0
        assert loader is None and not any(name.startswith('ElyxPlugins.') for name in sys.modules)
    elif _checks_handle is None:
        # The requires fixture must fail before any owned/neighbor entry executes.
        assert _load_calls == 1 and _entry_calls == 0 and not loader.plugins
    operations = ('construct', 'call', 'call_instance', 'get', 'get_instance', 'set', 'set_instance')
    value = {'threadId': _thread.get_ident(), 'pluginId': getattr(state, 'plugin_id', None),
             'ownerToken': getattr(state, 'owner_token', None), 'pluginSource': _loaded_source,
             'runtimeSource': getattr(runtime, '__file__', None), 'sdkSource': getattr(loader, '__file__', None),
             'handleCount': bridge.xt_handle_count() if bridge else 0,
             'callbackLeases': len(state.callbacks.leases) if state else 0,
             'loadedPlugins': sorted(loader.plugins) if loader else [],
             'bridgeBuiltin': bridge is not None and bridge.__spec__.origin == 'built-in' and type(bridge.xt_call_host) is type(len),
             'backendInstalled': bridge is not None and finder is not None and type(finder._State.backend) is bridge.BridgeBackend,
             'legacyServiceCount': sum(bool(bridge.xt_service_ptr('java.' + op)) for op in operations) if bridge else 0,
             'mockCalls': len(bridge.xt_mock_log()) if bridge else 0}
    sys.setprofile(None)
    return json.dumps(value, ensure_ascii=False, allow_nan=False)
