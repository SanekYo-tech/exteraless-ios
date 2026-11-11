"""python.bridge — C-мост ``_exteraless_bridge`` (этап 2 iOS-порта exteraless).

Пакет собирает вместе C-extension и классы virtualjava:

* ``BridgeBackend`` — реализация протокола ``python.virtualjava.backend.Backend``,
  маршрутизирующая вызовы в реестр нативных колбэков (на iOS их регистрирует
  Swift через ``xt_register_service``, на Windows — встроенный mock через
  ``xt_install_mock_service`` или ctypes-колбэки из тестов);
* handle-таблица (``xt_register_handle`` / ``xt_resolve_handle``) —
  JavaInstance и произвольные объекты ходят аргументами и результатами
  по int64-id, сохраняя identity. Таблица своя у каждого интерпретатора;
  ``xt_set_interpreter_id`` выбирает ещё одну таблицу внутри текущего.
  Swift освобождает слот через ``xt_builtin_ptr("release_handle")``
  (``xt_host_release_handle`` сам берёт GIL);
* ``bytes`` и неконечные float (``inf``/``-inf``/``nan``) идут по JSON
  тегами ``{"__bytes__": "<base64>"}`` и
  ``{"__float__": "inf"|"-inf"|"nan"}`` — см. комментарий в
  ``_exteraless_bridge.c``;
* ``member_kind``/``class_exists`` — из манифеста совместимости
  (``build/compat/manifest.json``, путь можно передать в ``BridgeBackend``).

Сборка (Windows/MSVC или любая платформа с компилятором)::

    cd python/bridge
    python setup.py build_ext --inplace

Контракт Swift-колбэков (сигнатуры, память, GIL) задокументирован в шапке
``_exteraless_bridge.c``.
"""

from . import _exteraless_bridge as _bridge

# Мост не знает путей импорта хоста: классы virtualjava передаём явно
# (на iOS python/ — корень пакетов, на десктопе — python.virtualjava).
try:  # pragma: no cover — зависит от точки входа хоста
    from virtualjava.backend import JavaMemberError as _JavaMemberError
    from virtualjava.proxy import JavaInstance as _JavaInstance
except ImportError:  # pragma: no cover
    from python.virtualjava.backend import JavaMemberError as _JavaMemberError
    from python.virtualjava.proxy import JavaInstance as _JavaInstance

_bridge.xt_bind(_JavaInstance, _JavaMemberError)

# --- публичное API (переэкспорт из C-extension) --------------------------

BridgeBackend = _bridge.BridgeBackend
xt_register_service = _bridge.xt_register_service
xt_unregister_service = _bridge.xt_unregister_service
xt_service_ptr = _bridge.xt_service_ptr
xt_install_mock_service = _bridge.xt_install_mock_service
xt_builtin_ptr = _bridge.xt_builtin_ptr
xt_mock_log = _bridge.xt_mock_log
xt_mock_log_clear = _bridge.xt_mock_log_clear
xt_register_handle = _bridge.xt_register_handle
xt_resolve_handle = _bridge.xt_resolve_handle
xt_release_handle = _bridge.xt_release_handle
xt_handle_count = _bridge.xt_handle_count
xt_clear_handles = _bridge.xt_clear_handles
xt_set_interpreter_id = _bridge.xt_set_interpreter_id

__all__ = [
    "BridgeBackend",
    "xt_register_service", "xt_unregister_service", "xt_service_ptr",
    "xt_install_mock_service", "xt_builtin_ptr",
    "xt_mock_log", "xt_mock_log_clear",
    "xt_register_handle", "xt_resolve_handle", "xt_release_handle",
    "xt_handle_count", "xt_clear_handles", "xt_set_interpreter_id",
]
