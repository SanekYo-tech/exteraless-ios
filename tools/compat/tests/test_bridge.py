"""Тесты C-моста _exteraless_bridge: BridgeBackend против virtualjava.

Ключевые сценарии test_virtualjava.py, прогнанные через BridgeBackend со
встроенным C-mock-сервисом (маршрутизация в реестр xt_register_service),
плюс специфика моста: handle-таблица (identity), манифест (member_kind /
class_exists) и регистрация Python-колбэка через ctypes — прототип пути,
которым на iOS Swift ставит свои колбэки.

Если расширение не собрано (python/bridge/_exteraless_bridge*.pyd),
тесты честно скипаются: pytest.importorskip.
"""

import ctypes
import json
import os
import sys

import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

pytest.importorskip("python.bridge._exteraless_bridge",
                    reason="C-мост не собран: cd python/bridge && "
                           "python setup.py build_ext --inplace")

from python.bridge import (  # noqa: E402
    BridgeBackend,
    xt_builtin_ptr,
    xt_clear_handles,
    xt_handle_count,
    xt_install_mock_service,
    xt_mock_log,
    xt_mock_log_clear,
    xt_register_handle,
    xt_register_service,
    xt_release_handle,
    xt_resolve_handle,
    xt_service_ptr,
    xt_unregister_service,
)
from python.virtualjava import (  # noqa: E402
    JavaInstance,
    JavaMemberError,
    install,
    reset_class_cache,
    uninstall,
)

MESSAGES_CONTROLLER = "org.telegram.messenger.MessagesController"
ANDROID_UTILITIES = "org.telegram.messenger.AndroidUtilities"
TLRPC_USER = "org.telegram.tgnet.TLRPC$User"
THEME = "org.telegram.ui.ActionBar.Theme"


@pytest.fixture(autouse=True)
def bridge_sandbox():
    """Каждый тест: чистая установка virtual-java на BridgeBackend + mock."""
    uninstall()
    reset_class_cache()
    xt_mock_log_clear()
    xt_clear_handles()
    xt_install_mock_service("java")
    backend = BridgeBackend(service="java")
    install(backend)
    yield backend
    uninstall()
    reset_class_cache()
    xt_clear_handles()


def log_last():
    return xt_mock_log()[-1]


# --- сценарии из test_virtualjava.py, против BridgeBackend ----------------

def test_package_import_and_static_call(bridge_sandbox):
    from org.telegram.messenger import MessagesController  # noqa: F401

    result = MessagesController.getInstance()
    entry = log_last()
    assert entry["op"] == "call"
    assert entry["fqcn"] == MESSAGES_CONTROLLER
    assert entry["member"] == "getInstance"
    assert result is not None


def test_plain_import_dotted(bridge_sandbox):
    import org.telegram.messenger.AndroidUtilities as AU  # noqa: F401

    AU.dp(10)
    entry = log_last()
    assert entry["fqcn"] == ANDROID_UTILITIES
    assert entry["member"] == "dp"
    assert entry["args"] == [10]


def test_nested_class_via_attribute(bridge_sandbox):
    from org.telegram.tgnet import TLRPC

    obj = TLRPC.User()
    entry = log_last()
    assert entry["op"] == "construct"
    assert entry["fqcn"] == TLRPC_USER
    assert entry["member"] == "<init>"
    assert isinstance(obj, JavaInstance)
    assert obj._fqcn == TLRPC_USER


def test_instance_call_uses_construct_handle(bridge_sandbox):
    from org.telegram.tgnet import TLRPC

    user = TLRPC.User()
    construct_handle = log_last()["handle"]
    user.getId()
    entry = log_last()
    assert entry["op"] == "call_instance"
    assert entry["fqcn"] == TLRPC_USER
    assert entry["member"] == "getId"
    # тот же handle, что выдал construct: identity через границу моста
    assert entry["handle"] == construct_handle


def test_str_calls_tostring(bridge_sandbox):
    from org.telegram.tgnet import TLRPC

    user = TLRPC.User()
    str(user)
    toString = [e for e in xt_mock_log() if e["member"] == "toString"]
    assert toString, "str() должен звать toString"


def test_static_field_set_and_get_by_manifest(bridge_sandbox):
    # density — объявленное поле AndroidUtilities в манифесте:
    # member_kind => "field" => set/get, а не call.
    from org.telegram.messenger import AndroidUtilities  # noqa: F401

    AndroidUtilities.density = 2.0
    entry = log_last()
    assert entry["op"] == "set"
    assert entry["fqcn"] == ANDROID_UTILITIES
    assert entry["member"] == "density"
    assert entry["args"] == 2.0

    value = AndroidUtilities.density
    entry = log_last()
    assert entry["op"] == "get"
    assert entry["member"] == "density"
    assert value is not None


def test_field_get_by_manifest_theme_key(bridge_sandbox):
    # Пример из ТЗ: Theme.key_windowBackgroundWhiteBlackText — поле.
    # Класс берём через jclass: org.telegram.ui.ActionBar — пакет с
    # заглавной буквы, from-import даёт вложенный класс ActionBar$Theme.
    from java import jclass

    Theme = jclass(THEME)
    value = Theme.key_windowBackgroundWhiteBlackText
    entry = log_last()
    assert entry["op"] == "get"
    assert entry["fqcn"] == THEME
    assert entry["member"] == "key_windowBackgroundWhiteBlackText"
    assert value is not None


def test_method_kind_routes_to_call_not_get(bridge_sandbox):
    # dp не поле => метод => static call (не get).
    from org.telegram.messenger import AndroidUtilities  # noqa: F401

    AndroidUtilities.dp(10)
    entry = log_last()
    assert entry["op"] == "call"
    assert entry["member"] == "dp"


def test_kwargs_marshalled(bridge_sandbox):
    from org.telegram.messenger import MessagesController  # noqa: F401

    MessagesController.someStatic(1, flag=True)
    entry = log_last()
    assert entry["args"] == [1]
    assert entry["kwargs"] == {"flag": True}


# --- handle-таблица: объект -> call -> тот же объект обратно ---------------

def test_handle_roundtrip_arbitrary_object(bridge_sandbox):
    from org.telegram.tgnet import TLRPC

    user = TLRPC.User()
    sentinel = object()
    echoed = user.echoFirst(sentinel)
    assert echoed is sentinel, "тот же объект должен вернуться по handle"


def test_handle_roundtrip_java_instance(bridge_sandbox):
    from org.telegram.tgnet import TLRPC

    user = TLRPC.User()
    echoed = user.echoFirst(user)
    assert echoed is user, "JavaInstance проходит по handle без копирования"


def test_handle_roundtrip_scalars_and_containers(bridge_sandbox):
    from org.telegram.messenger import MessagesController  # noqa: F401

    for value in (10, 2.5, "héllo", True, None, [1, "x", False],
                  {"a": 1, "b": [2.5]}):
        echoed = MessagesController.echoFirst(value)
        assert echoed == value
        assert type(echoed) is type(value)


def test_handle_table_direct_api():
    obj = object()
    handle = xt_register_handle(obj)
    assert xt_resolve_handle(handle) is obj
    # повторная регистрация — тот же id
    assert xt_register_handle(obj) == handle
    assert xt_handle_count() >= 1
    assert xt_release_handle(handle) is True
    assert xt_resolve_handle(handle) is None
    assert xt_release_handle(handle) is False


def test_unknown_class_construct_raises(bridge_sandbox):
    with pytest.raises(JavaMemberError):
        bridge_sandbox.construct("no.such.Klass", ())


def test_unknown_class_static_call_raises(bridge_sandbox):
    with pytest.raises(JavaMemberError):
        bridge_sandbox.call("no.such.Klass", "member", (), {})


def test_member_kind_and_class_exists_by_manifest(bridge_sandbox):
    backend = bridge_sandbox
    assert backend.member_kind(THEME,
                               "key_windowBackgroundWhiteBlackText") == "field"
    assert backend.member_kind(ANDROID_UTILITIES, "dp") == "method"
    assert backend.member_kind("no.such.Klass", "member") == "unknown"
    assert backend.class_exists(TLRPC_USER) is True
    assert backend.class_exists("no.such.Klass") is False


def test_missing_service_raises_member_error(bridge_sandbox):
    backend = BridgeBackend(service="absent")
    with pytest.raises(JavaMemberError):
        backend.call(MESSAGES_CONTROLLER, "getInstance", (), {})


# --- реестр сервисов: путь Swift (регистрация указателей) ------------------

def test_service_registry_introspection():
    # встроенный mock зарегистрирован; адрес ненулевой; unregister работает
    ptr = xt_service_ptr("java.call")
    assert ptr != 0
    assert xt_service_ptr("java.no-such-op") == 0
    # пере-регистрация встроенной mock-функции под другим префиксом
    xt_register_service("echo.call", xt_builtin_ptr("call"))
    try:
        backend = BridgeBackend(service="echo")
        install(backend)
        backend.call(MESSAGES_CONTROLLER, "getInstance", (), {})
        assert log_last()["op"] == "call"
    finally:
        uninstall()
        xt_unregister_service("echo.call")


def test_service_error_marker_raises_member_error():
    # сервис отвечает {"__error__": ...} => JavaMemberError
    CFUNC = ctypes.CFUNCTYPE(
        ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p,
        ctypes.c_char_p, ctypes.POINTER(ctypes.c_char_p))
    libc = ctypes.CDLL("ucrtbase.dll")
    libc.malloc.restype = ctypes.c_void_p
    libc.malloc.argtypes = [ctypes.c_size_t]

    def err_call(fqcn, member, json_args, result):
        payload = json.dumps({"__error__": "boom from host"}).encode()
        buf = libc.malloc(len(payload) + 1)
        ctypes.memmove(buf, payload, len(payload) + 1)
        result[0] = ctypes.cast(ctypes.c_void_p(buf), ctypes.c_char_p)
        return 0

    cb = CFUNC(err_call)   # держим ссылку: колбэк должен жить
    xt_register_service("hosterr.call", ctypes.cast(cb, ctypes.c_void_p).value)
    try:
        backend = BridgeBackend(service="hosterr")
        install(backend)
        with pytest.raises(JavaMemberError, match="boom from host"):
            backend.call(MESSAGES_CONTROLLER, "getInstance", (), {})
    finally:
        uninstall()
        xt_unregister_service("hosterr.call")


def test_python_ctypes_service_swift_path():
    """Регистрация Python-колбэка через ctypes — прототип регистрации Swift.

    Колбэк вызывается с удержанным GIL (контракт моста), получает UTF-8
    JSON, отвечает malloc()-памятью ucrtbase (мост зовёт free() из той же
    CRT). Возврат handle-маркера первого аргумента — как настоящий Swift.
    """
    CFUNC = ctypes.CFUNCTYPE(
        ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p,
        ctypes.c_char_p, ctypes.POINTER(ctypes.c_char_p))
    libc = ctypes.CDLL("ucrtbase.dll")
    libc.malloc.restype = ctypes.c_void_p
    libc.malloc.argtypes = [ctypes.c_size_t]
    seen = []

    def py_call(fqcn, member, json_args, result):
        seen.append((fqcn.decode() if fqcn else None,
                     member.decode() if member else None,
                     json.loads(json_args.decode("utf-8"))))
        args = seen[-1][2]["args"]
        # echo: первый аргумент возвращаем как результат (маркер или скаляр)
        out_obj = args[0] if args else None
        payload = json.dumps(out_obj, ensure_ascii=False).encode("utf-8")
        buf = libc.malloc(len(payload) + 1)
        ctypes.memmove(buf, payload, len(payload) + 1)
        result[0] = ctypes.cast(ctypes.c_void_p(buf), ctypes.c_char_p)
        return 0

    cb = CFUNC(py_call)
    xt_register_service("pysvc.call", ctypes.cast(cb, ctypes.c_void_p).value)
    try:
        backend = BridgeBackend(service="pysvc")
        install(backend)
        from org.telegram.messenger import MessagesController  # noqa: F401

        # скаляр: эхо значения
        assert MessagesController.echoFirst(42) == 42
        # объект: эхо handle-маркера => ТОТ ЖЕ объект
        sentinel = object()
        assert MessagesController.echoFirst(sentinel) is sentinel
        assert seen[-1][0] == MESSAGES_CONTROLLER
        assert seen[-1][1] == "echoFirst"
    finally:
        uninstall()
        xt_unregister_service("pysvc.call")
