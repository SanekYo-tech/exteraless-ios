"""Изоляция handle-таблицы C-моста: явный interpreter id и суб-интерпретатор.

Две таблицы не делят слоты. Суб-интерпретатор (PEP 684) получает свой
module state; если рантайм не пускает расширение, тест честно падает —
это и есть проверка слота Py_mod_multiple_interpreters.
"""

import ctypes
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
    xt_builtin_ptr,
    xt_clear_handles,
    xt_register_handle,
    xt_release_handle,
    xt_resolve_handle,
    xt_set_interpreter_id,
)


@pytest.fixture(autouse=True)
def _home_realm():
    home = xt_set_interpreter_id(0)
    xt_set_interpreter_id(home)
    xt_clear_handles()
    yield home
    xt_set_interpreter_id(home)
    xt_clear_handles()


def test_explicit_interpreter_ids_do_not_share_handles():
    home = xt_set_interpreter_id(101)
    try:
        obj = object()
        hid = xt_register_handle(obj)
        assert xt_set_interpreter_id(202) == 101
        # тот же числовой id в другой таблице — не тот объект
        assert xt_resolve_handle(hid) is None
        assert xt_release_handle(hid) is False
        release = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int64)(
            xt_builtin_ptr("release_handle"))
        assert release(hid) == 0
        other = object()
        oid = xt_register_handle(other)
        assert xt_resolve_handle(oid) is other
        xt_clear_handles()
        assert xt_set_interpreter_id(101) == 202
        assert xt_resolve_handle(hid) is obj
        assert release(hid) == 1
        assert xt_resolve_handle(hid) is None
        xt_clear_handles()
    finally:
        xt_set_interpreter_id(home)


def test_subinterpreter_cannot_see_or_release_handles():
    ci = pytest.importorskip("concurrent.interpreters")
    obj = object()
    hid = xt_register_handle(obj)
    code = f"""
import sys
sys.path.insert(0, {REPO_ROOT!r})
from python.bridge import (
    xt_register_handle, xt_release_handle, xt_resolve_handle,
)
seen = xt_resolve_handle({hid})
if seen is not None:
    raise AssertionError("handle leaked across interpreters")
if xt_release_handle({hid}) is not False:
    raise AssertionError("foreign release dropped a handle")
local = object()
local_id = xt_register_handle(local)
if xt_resolve_handle(local_id) is not local:
    raise AssertionError("local handle did not round-trip")
if xt_release_handle(local_id) is not True:
    raise AssertionError("local release failed")
if xt_resolve_handle(local_id) is not None:
    raise AssertionError("local handle survived release")
"""
    interp = ci.create()
    try:
        interp.exec(code)
    finally:
        interp.close()
    assert xt_resolve_handle(hid) is obj
    xt_release_handle(hid)
