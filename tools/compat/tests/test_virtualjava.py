"""Тесты virtual-java: импорт, прокси, вызовы, вложенные классы, мок."""

import os
import sys

import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))))
sys.path.insert(0, REPO_ROOT)

from python.virtualjava import (  # noqa: E402
    MockBackend, install, uninstall, reset_class_cache)


@pytest.fixture(autouse=True)
def sandbox():
    """Каждый тест — чистая установка virtual-java."""
    uninstall()
    reset_class_cache()
    backend = MockBackend()
    install(backend)
    yield backend
    uninstall()
    reset_class_cache()


def test_package_import_and_static_call(sandbox):
    from org.telegram.messenger import MessagesController  # noqa: F401
    result = MessagesController.getInstance()
    assert sandbox.calls[-1].kind == "static"
    assert sandbox.calls[-1].target == "org.telegram.messenger.MessagesController"
    assert sandbox.calls[-1].member == "getInstance"
    assert result is not None


def test_plain_import_dotted(sandbox):
    import org.telegram.messenger.AndroidUtilities as AU  # noqa: F401
    AU.dp(10)
    assert sandbox.calls[-1].target == "org.telegram.messenger.AndroidUtilities"
    assert sandbox.calls[-1].member == "dp"
    assert sandbox.calls[-1].args == (10,)


def test_nested_class_via_attribute(sandbox):
    from org.telegram.tgnet import TLRPC
    obj = TLRPC.TL_updateNewMessage()
    assert sandbox.calls[-1].kind == "new"
    assert sandbox.calls[-1].target == \
        "org.telegram.tgnet.TLRPC$TL_updateNewMessage"


def test_instance_call(sandbox):
    from org.telegram.tgnet import TLRPC
    update = TLRPC.TL_updateNewMessage()
    update.getMessage()
    assert sandbox.calls[-1].kind == "instance"
    assert sandbox.calls[-1].member == "getMessage"


def test_str_calls_tostring(sandbox):
    from org.telegram.tgnet import TLRPC
    update = TLRPC.TL_updateNewMessage()
    str(update)
    toString = [c for c in sandbox.calls if c.member == "toString"]
    assert toString, "str() должен звать toString"


def test_static_field_and_setattr(sandbox):
    from org.telegram.messenger import AndroidUtilities
    AndroidUtilities.density = 2.0
    assert sandbox.calls[-1].kind == "sset"
    assert sandbox.calls[-1].member == "density"
    value = AndroidUtilities.density
    assert sandbox.calls[-1].kind == "sfield"


def test_aliased_import_resolves(sandbox):
    # com.exteragram.* -> app.exteraless.* через class_aliases.py (vendored).
    from com.exteragram.messenger.plugins import Plugin
    Plugin.getInstance()
    target = sandbox.calls[-1].target
    assert target.startswith(("com.exteragram.", "app.exteraless."))


def test_chaquopy_jclass(sandbox):
    from java import jclass
    cls = jclass("org.telegram.messenger.MessagesController")
    cls.getInstance()
    assert sandbox.calls[-1].target == \
        "org.telegram.messenger.MessagesController"


def test_subpackage_lazily_registered(sandbox):
    from org.telegram import messenger  # noqa: F401
    assert "org.telegram.messenger" in sys.modules


def test_uninstall_cleans_modules(sandbox):
    from org.telegram.messenger import MessagesController  # noqa: F401
    uninstall()
    assert not any(m.split(".", 1)[0] == "org" for m in sys.modules)
