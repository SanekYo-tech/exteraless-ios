"""SDK06-09: own tiny fixtures in isolated <=30s children, no plugin execution.

The optional C test needs an explicit matching extension/build receipt. The
optional Foundation test needs the small prebuilt native_codec.swift fixture.
Neither test substitutes a Python recorder for native execution.
"""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import sysconfig


ROOT = Path(__file__).resolve().parents[3]
FIXTURE = Path(__file__).with_name("fixtures") / "java_values"
CASES = ("primitive_identity", "array_identity", "interpreter_cache", "reference_arrays", "byte_fields",
         "boxed_values", "map_keys", "map_views", "map_iterators", "set_keys", "scalar_codec")


def raises(kind, action, text=""):
    try:
        action()
    except kind as error:
        assert text in str(error), (text, error)
    else:
        raise AssertionError(f"Expected {kind.__name__}: {text}")


def bootstrap():
    sys.path[:0] = [str(ROOT / "python"), str(ROOT / "python/sdk")]
    import virtualjava
    from exteraless_runtime import _java_types

    class NoHost:
        def __getattr__(self, name): raise AssertionError(f"Unexpected native operation: {name}")

    virtualjava.install(NoHost())
    _java_types.install()
    return _java_types


def byte_cases():
    from java import jarray, jbyte, jclass, jint, jlong
    from exteraless_runtime._java_types import Long
    from exteraless_runtime._tl import Schema, to_wire
    schema = Schema(FIXTURE / "schema.json")
    # The tiny schema uses exact shipping records, not a permissive test schema.
    full = json.loads((ROOT / "python/runtime/tl-schema.json").read_text(encoding="utf-8"))
    definitions = {row["name"]: row for row in full["constructors"] + full["methods"]}
    assert all(record == definitions[name] for name, record in schema.definitions.items())
    Peer = jclass("org.telegram.tgnet.TLRPC$TL_inputPeerSelf")
    Request = jclass("org.telegram.tgnet.TLRPC$TL_messages_getBotCallbackAnswer")
    Password = jclass("org.telegram.tgnet.TLRPC$TL_inputCheckPasswordSRP")
    ByteArray = jarray(jbyte)
    signed = [-128, -1, 0, 127]
    rows = []
    for name, data in (("empty", ByteArray()), ("signed", ByteArray(signed)),
                       ("plain_control", b"\x80\xff\x00\x7f")):
        rows.append({"name": name, "request": to_wire(Request(peer=Peer(), msg_id=7, data=data))})
    rows.append({"name": "nested", "request": to_wire(Request(peer=Peer(), msg_id=7, data=ByteArray(),
        password=Password(srp_id=Long(9007199254740993), A=ByteArray(signed), M1=ByteArray())))})
    for name, data in (("int_vector", jarray(jint)(signed)), ("long_vector", jarray(jlong)(signed)),
                       ("invalid_base64", {"__bytes__": "***"})):
        rows.append({"name": name, "reject": True, "request": to_wire(Request(peer=Peer(), msg_id=7, data=data))})
    return {"sourceSHA256": full["sourceSHA256"], "nativeLayoutHash": full["nativeLayoutHash"], "cases": rows}


def check_byte_cases(payload):
    by_name = {row["name"]: row["request"] for row in payload["cases"]}
    assert by_name["empty"]["data"] == {"__bytes__": ""}
    assert by_name["signed"]["data"] == {"__bytes__": "gP8Afw=="}
    assert by_name["signed"] == by_name["plain_control"]
    assert by_name["nested"]["password"] == {"_": "inputCheckPasswordSRP", "srp_id": 9007199254740993,
        "A": {"__bytes__": "gP8Afw=="}, "M1": {"__bytes__": ""}}
    assert by_name["int_vector"]["data"] == by_name["long_vector"]["data"] == [-128, -1, 0, 127]


def native_c(directory, bridge_path, receipt_path):
    bridge_path, receipt_path = Path(bridge_path), Path(receipt_path)
    assert bridge_path.name.endswith(sysconfig.get_config_var("EXT_SUFFIX")), "CPython ABI mismatch"
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    assert hashlib.sha256(bridge_path.read_bytes()).hexdigest() == receipt["extension_sha256"]
    for relative in ("python/bridge/_exteraless_bridge.c", "python/runtime/include/EXLPythonBridge.h"):
        assert hashlib.sha256((ROOT / relative).read_bytes()).hexdigest() == receipt["source_fingerprint"][relative]
    spec = importlib.util.spec_from_file_location("_exteraless_bridge", bridge_path)
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    from exteraless_runtime._java_types import Boolean, HashMap, Integer, Long
    manifest = Path(directory) / "java-values-manifest.json"
    manifest.write_text(json.dumps({"classes": {"fixture.JavaValues": {"declared": {"fields": ["payload"]}}}}), encoding="utf-8")
    bridge.xt_install_mock_service("java_values")
    backend = bridge.BridgeBackend(service="java_values", manifest_path=str(manifest))
    try:
        mapping = HashMap([(Integer(1), Long(9007199254740993)), (Long(1), Long(-(2 ** 63)))])
        values = [Integer(-(2 ** 31)), Integer(2 ** 31 - 1), mapping.get(Integer(1)), mapping.get(Long(1)),
                  Long(2 ** 63 - 1), Boolean(True).booleanValue(), False, None]
        result = backend.call("fixture.JavaValues", "echoFirst", (values,), {})
        assert result == [-2147483648, 2147483647, 9007199254740993, -(2 ** 63), 2 ** 63 - 1, True, False, None]
        assert [type(value) for value in result] == [int] * 5 + [bool, bool, type(None)]
        backend.set("fixture.JavaValues", "payload", HashMap({"large": Long(9007199254740993), "null": None}))
        assert bridge.xt_mock_log()[-1]["args"] == {"large": 9007199254740993, "null": None}
        payload = byte_cases()
        check_byte_cases(payload)
        for row in payload["cases"][:4]:
            backend.set("fixture.JavaValues", "payload", row["request"])
            assert bridge.xt_mock_log()[-1]["args"] == row["request"]
            decoded = backend.call("fixture.JavaValues", "echoFirst", (row["request"],), {})
            assert decoded["data"] == (b"" if row["name"] in ("empty", "nested") else b"\x80\xff\0\x7f")
            if row["name"] == "nested":
                assert decoded["password"]["A"] == b"\x80\xff\0\x7f"
                assert decoded["password"]["srp_id"] == 9007199254740993
        raises(ValueError, lambda: backend.call("fixture.JavaValues", "echoFirst", ({"__bytes__": "***"},), {}), "__bytes__")
        raises(OverflowError, lambda: backend.call("fixture.JavaValues", "echoFirst", (Long(2 ** 63),), {}), "int64")
        assert bridge.xt_handle_count() == 0
    finally:
        for operation in ("construct", "call", "call_instance", "get", "get_instance", "set", "set_instance"):
            bridge.xt_unregister_service("java_values." + operation)
    print("JAVA_VALUES_C_OK: exact Int64, byte markers, strict C base64 control, zero handles")


def native_codec(executable):
    payload = byte_cases()
    check_byte_cases(payload)
    result = subprocess.run([executable], input=json.dumps(payload), text=True, encoding="utf-8",
                            capture_output=True, timeout=20)
    assert result.returncode == 0, result.stdout + result.stderr
    rows = json.loads(result.stdout)
    assert [row["name"] for row in rows] == [row["name"] for row in payload["cases"]]
    for source, result in zip(payload["cases"], rows):
        if source.get("reject"):
            assert result["rejected"] is True and "bytes" in result["error"]
        else:
            normalized = result["normalized"]
            assert normalized == dict(source["request"], flags=5 if source["name"] == "nested" else 1, game=False)
    print("JAVA_VALUES_NATIVE_TL_OK: actual encode/decode and strict bytes validation")


def worker(case, directory, *native_args):
    types = bootstrap()
    from java import cast, jarray, jboolean, jbyte, jchar, jclass, jdouble, jfloat, jint, jlong, jshort, jvoid
    from exteraless_runtime._tl import to_wire
    Integer, Long, Boolean, HashMap, HashSet = types.Integer, types.Long, types.Boolean, types.HashMap, types.HashSet
    if case == "primitive_identity":
        import java
        for name, converter, descriptor, default in (
            ("jbyte", jbyte, "B", 0), ("jshort", jshort, "S", 0), ("jint", jint, "I", 0),
            ("jlong", jlong, "J", 0), ("jfloat", jfloat, "F", 0.0), ("jdouble", jdouble, "D", 0.0),
            ("jboolean", jboolean, "Z", False), ("jchar", jchar, "C", "\0"), ("jvoid", jvoid, "V", None)):
            assert getattr(java, name) is converter
            assert getattr(__import__("java", fromlist=[name]), name) is converter
            assert converter._java_descriptor == descriptor
            if converter is jvoid: continue
            array = jarray(converter)
            assert array is jarray(name[1:]) is jarray(descriptor)
            assert array.component_type is converter and array.component_descriptor == descriptor
            assert array._java_descriptor == "[" + descriptor
            assert array(2) == [default, default]
            raises(TypeError, lambda: array([None]), "null")
        assert jint is not jlong and jfloat is not jdouble
        assert jarray(int) is jarray(jint) and jarray(float) is jarray(jdouble) and jarray(bool) is jarray(jboolean)
        assert jbyte(128, truncate=True) == -128 and jbyte(255, truncate=True) == -1
        assert jint(0xffffffff, truncate=True) == -1 and jlong(2 ** 64 - 1, truncate=True) == -1
        raises(OverflowError, lambda: jbyte(128), "jbyte")
        raises(OverflowError, lambda: jint(2 ** 31), "jint")
        assert jchar(0x20ac) == "€"
        raises(ValueError, lambda: jchar("😀"), "UTF-16")
        raises(TypeError, lambda: jarray(jvoid), "void")
        raises(TypeError, lambda: jarray(lambda value: value), "descriptor")
    elif case == "array_identity":
        first = jarray(jint)([1, 2])
        assert isinstance(first, jarray(jint)) and cast(jarray(jint), first) is first
        assert jclass("[I") is jclass("int[]") is jarray(jint)
        assert cast("[I", first) is first and cast(jarray(jint), None) is None
        assert not isinstance(first, jarray(jlong))
        raises(TypeError, lambda: cast(jarray(jlong), first), "cannot cast")
        nested = jarray(jarray(jint))([first, None])
        assert jarray(jarray(jint)) is jarray("int[]") is jarray("[I") is jclass("[[I")
        assert isinstance(nested, jarray(jarray(jint))) and cast("int[][]", nested) is nested
        assert jarray(jarray(jint))(2) == [None, None]
        raises(TypeError, lambda: nested.__setitem__(0, jarray(jlong)([1])), "[I")
        first[0] = 7
        first[:] = [8, 9]
        assert list(first) == [8, 9] and nested[0] is first
        raises(TypeError, lambda: first.append(3), "fixed")
        raises(TypeError, lambda: first.__setitem__(slice(None), [3]), "fixed")
        raises(OverflowError, lambda: first.__setitem__(0, 2 ** 31), "jint")
        assert first == [8, 9]
    elif case == "reference_arrays":
        String, Object = jclass("java.lang.String"), jclass("java.lang.Object")
        strings = jarray(String)([String("value"), None, "plain"])
        assert jarray(String) is jarray("java.lang.String") is jarray("Ljava/lang/String;")
        assert jarray(Object)(3) == [None, None, None]
        assert cast(jarray(Object), strings) is strings
        assert isinstance(jarray(jarray(jint))([jarray(jint)([1]), None]), jarray(Object))
        assert not isinstance(jarray(jint)([1]), jarray(Object))
        strings[1] = None
        raises(TypeError, lambda: strings.__setitem__(0, Integer(1)), "String")
        raises(TypeError, lambda: jarray(Integer)([Long(1)]), "Integer")
        assert not isinstance(jarray(Long)([Long(1)]), jarray(Integer))
        # Explicit names keep identity even for two Java names using one port.
        assert jclass("java.util.HashMap") is jclass("java.util.LinkedHashMap")
        assert jarray("java.util.HashMap") is not jarray("java.util.LinkedHashMap")
        assert not isinstance(jarray("java.util.HashMap")(), jarray("java.util.LinkedHashMap"))
        native = jclass("fixture.NativeReference")
        from virtualjava import JavaInstance
        value = JavaInstance("fixture.NativeReference", None)
        assert jarray(native) is jarray("fixture.NativeReference")
        assert jarray(native)([value, None])[0] is value
        raises(TypeError, lambda: jarray(native)([Object()]), "NativeReference")
    elif case == "interpreter_cache":
        jarray(jint)._fixture_owner = "parent"
        code = f'''
import sys
sys.path.insert(0, {str(ROOT / "python")!r})
import virtualjava
virtualjava.install(object())
from java import jarray, jint, jlong
import java
assert jint is java.jint and jint is not jlong
assert jarray(jint) is jarray("I") and jarray(jlong) is not jarray(jint)
assert not hasattr(jarray(jint), "_fixture_owner")
assert not hasattr(jint, "_fixture_owner")
jarray(jint)._fixture_owner = "child"
jint._fixture_owner = "child"
'''
        children = []
        try:
            if sys.version_info >= (3, 14):
                from concurrent import interpreters
                children = [interpreters.create(), interpreters.create()]
                for child in children: child.exec(code)
            else:
                import _xxsubinterpreters as interpreters
                children = [interpreters.create(), interpreters.create()]
                for child in children: interpreters.run_string(child, code)
        finally:
            for child in children:
                if sys.version_info >= (3, 14): child.close()
                else: interpreters.destroy(child)
        assert jarray(jint)._fixture_owner == "parent" and not hasattr(jint, "_fixture_owner")
    elif case == "byte_fields":
        check_byte_cases(byte_cases())
        values = jarray(jbyte)(4)
        values[:] = [-128, -1, 0, 127]
        assert to_wire(values) == {"__bytes__": "gP8Afw=="}
        assert to_wire(jarray(jarray(jbyte))([values, None])) == [{"__bytes__": "gP8Afw=="}, None]
        assert to_wire(jarray(jclass("java.lang.Integer"))([Integer(-1)])) == [-1]
        assert to_wire(jarray(jlong)([9007199254740993])) == [9007199254740993]
        raises(OverflowError, lambda: jarray(jbyte)([255]), "jbyte")
    elif case == "boxed_values":
        assert Integer(1).equals(Integer(1)) and Long(1).equals(Long(1))
        assert not Integer(1).equals(Long(1)) and not Long(1).equals(Integer(1))
        assert not Integer(1).equals(1) and not Long(1).equals(None)
        assert Integer(-1).hashCode() == -1 and Long(-1).hashCode() == 0
        assert Long(9007199254740993).hashCode() == 2097153
        assert Long(-(2 ** 63)).hashCode() == -2147483648
        assert Long(2 ** 63 - 1).hashCode() == -2147483648
        # int storage/operators remain the SDK's Python scalar contract.
        assert Integer(1) == Long(1) == 1 and hash(Integer(1)) == hash(Long(1)) == hash(1)
        assert Long(9007199254740993) + 2 == 9007199254740995
        assert (Integer(-1) & 0xffffffff) == 0xffffffff
        values = types.ArrayList([1, 2])
        assert values.remove(Integer(1)) is True and values == [2]
        left, right = Boolean(True), Boolean(True)
        assert left is not right and left.equals(right) and left == right
        assert hash(left) == hash(right) == left.hashCode() == 1231
        assert Boolean(False).hashCode() == 1237 and not left.equals(Boolean(False))
        assert not left.equals(Integer(1)) and not left.equals(True) and not left.equals(None)
        assert Boolean("true").booleanValue() is True and Boolean("false").booleanValue() is False
        raises(AttributeError, lambda: setattr(left, "value", False))
    elif case == "map_keys":
        mapping = HashMap()
        for key, value in ((Integer(1), "integer"), (Long(1), "long"), (Boolean(True), "boolean"), (None, None)):
            assert mapping.put(key, value) is None
        assert mapping.size() == 4
        assert mapping.get(Integer(1)) == "integer" and mapping.get(Long(1)) == "long"
        assert mapping.put(Boolean(True), "updated") == "boolean" and mapping.size() == 4
        assert mapping.containsKey(None) and mapping.containsValue(None)
        assert mapping.put(None, "nonnull") is None and mapping.put(None, None) == "nonnull"
        assert mapping.remove(Integer(1)) == "integer" and mapping.remove(Integer(1)) is None
        assert mapping.containsKey(Long(1)) and mapping.remove(None) is None and not mapping.containsKey(None)
        mapping.update([(Integer(1), Long(9007199254740993)), (Boolean(False), None)])
        copy = HashMap(mapping)
        assert copy == mapping and copy.hashCode() == mapping.hashCode()
        assert copy.get(Integer(1)).longValue() == 9007199254740993
        assert {type(key) for key in copy} == {Integer, Long, Boolean}
        assert all(type(key).__name__ != "_JavaKey" for key, value in copy.items())
        assert copy.setdefault(Long(1), "ignored") == "long"
        assert copy.pop(Long(1)) == "long" and copy.get(Integer(1)) == 9007199254740993
        assert copy.pop(Long(1), "absent") == "absent"
        raises(KeyError, lambda: copy.pop(Long(1)))
        copy |= [(Long(1), "restored")]
        assert copy.get(Long(1)) == "restored"
        assert HashMap({"value": Integer(1)}).containsValue(Long(1)) is False
        assert not HashMap({"value": Integer(1)}).equals(HashMap({"value": Long(1)}))
        assert HashMap({"value": 1}) == {"value": 1}
        assert HashMap({"value": 1}).keys() & {"value"} == {"value"}
        assert dict(HashMap({"value": 1})) == {"value": 1}
    elif case == "map_views":
        mapping = HashMap({"x": 1})
        keys, entries = mapping.keySet(), mapping.entrySet()
        mapping.put("y", 2)
        assert list(keys) == ["x", "y"] and entries.size() == 2
        entry = entries.get(0)
        assert entry.getKey() == "x" and entry.setValue(3) == 1 and mapping.get("x") == 3
        assert mapping.put("x", 4) == 3 and entry.getValue() == 4
        assert entries.contains(types.Entry(HashMap({"x": 4}), "x"))
        assert not entries.remove(types.Entry(HashMap({"x": 7}), "x"))
        assert entries.remove(types.Entry(HashMap({"x": 4}), "x")) and not mapping.containsKey("x")
        raises(KeyError, lambda: entry.setValue(5), "entry was removed")
        assert not keys.remove("missing")
        mapping.put(None, None)
        assert keys.remove(None) is True and not mapping.containsKey(None)
        raises(TypeError, lambda: keys.add("new"), "keySet.add")
        raises(TypeError, lambda: keys.addAll(["new"]), "keySet.addAll")
        raises(TypeError, lambda: entries.add(types.Entry(mapping, "y")), "entrySet.add")
        keys.clear()
        assert mapping.isEmpty() and entries.isEmpty()
        mapping.put("z", 9)
        assert keys.contains("z") and entries.iterator().next().getValue() == 9
        entries.clear()
        assert mapping.isEmpty() and keys.isEmpty()
        mapping.update([(Integer(1), "int"), (Long(1), "long"), (Integer(2), "two")])
        assert keys.remove(Integer(1)) is True and mapping.get(Long(1)) == "long"
        assert keys.retainAll([Long(1)]) is True and list(keys) == [Long(1)]
        assert keys.removeAll(keys) is True and mapping.isEmpty()
    elif case == "map_iterators":
        mapping = HashMap([(Integer(1), "int"), (Long(1), "long"), (None, None)])
        iterator = mapping.entrySet().iterator()
        raises(RuntimeError, iterator.remove, "preceding next")
        entry = iterator.next()
        assert type(entry.getKey()) is Integer
        assert entry.setValue("updated") == "int"
        iterator.remove()
        raises(RuntimeError, iterator.remove, "preceding next")
        assert mapping.size() == 2 and not mapping.containsKey(Integer(1))
        assert type(iterator.next().getKey()) is Long
        assert iterator.next().getKey() is None and not iterator.hasNext()
        raises(StopIteration, iterator.next)
        iterator.remove()
        assert not mapping.containsKey(None)
        iterator = mapping.keySet().iterator()
        mapping.put(Long(1), "new value")
        assert type(iterator.next()) is Long  # Value replacement isn't structural.
        stale = mapping.keySet().iterator()
        mapping.remove(Long(1))
        mapping.put(Integer(2), "same-size replacement")
        raises(RuntimeError, stale.next, "structurally modified")
        raises(RuntimeError, stale.remove, "structurally modified")
        iterator = iter(mapping.entrySet())
        mapping.clear()
        raises(RuntimeError, lambda: next(iterator), "structurally modified")
    elif case == "set_keys":
        values = HashSet([Integer(1), Long(1), Boolean(True), Boolean(True), None])
        assert values.size() == 4 and not values.add(Integer(1))
        assert values.remove(Long(1)) and values.contains(Integer(1)) and not values.contains(Long(1))
        assert values.contains(Boolean(True)) and values.remove(None)
        assert values.copy() == values and values.copy().hashCode() == values.hashCode()
        assert values.union([Long(1)]).size() == 3
        assert values.intersection([Integer(1)]).size() == 1
        assert values.difference([Boolean(True)]).size() == 1
        iterator = values.iterator()
        first = iterator.next()
        iterator.remove()
        assert not values.contains(first)
    elif case == "scalar_codec":
        from exteraless_runtime import _codec
        values = [Long(9007199254740993), Integer(-1), Boolean(True).booleanValue(), None]
        result = _codec.loads(_codec.dumps(values))
        assert result == [9007199254740993, -1, True, None]
        assert [type(value) for value in result] == [int, int, bool, type(None)]
        assert _codec.loads(_codec.dumps(HashMap({"large": values[0], "flag": True}))) == {"large": 9007199254740993, "flag": True}
        raises(OverflowError, lambda: _codec.dumps(Long(2 ** 63)), "int64")
    elif case == "native_c":
        native_c(directory, *native_args)
    elif case == "native_codec":
        native_codec(*native_args)
    else:
        raise AssertionError(case)


if __name__ == "__main__":
    worker(*sys.argv[1:])
else:
    import pytest

    def run_child(case, tmp_path, *native_args):
        result = subprocess.run([sys.executable, "-I", "-S", "-B", "-X", "utf8", str(Path(__file__).resolve()),
                                 case, str(tmp_path), *native_args], cwd=tmp_path,
                                text=True, encoding="utf-8", capture_output=True, timeout=30)
        assert result.returncode == 0, result.stdout + result.stderr

    @pytest.mark.parametrize("case", CASES)
    def test_java_value_regression(case, tmp_path):
        run_child(case, tmp_path)

    def test_java_values_through_real_c(tmp_path):
        bridge = os.environ.get("EXTERALESS_JAVA_BRIDGE")
        receipt = os.environ.get("EXTERALESS_JAVA_BRIDGE_RECEIPT")
        if not bridge or not receipt:
            pytest.skip("native C pending: supply a matching extension and its build receipt")
        run_child("native_c", tmp_path, bridge, receipt)

    def test_java_bytes_through_native_tl_codec(tmp_path):
        executable = os.environ.get("EXTERALESS_JAVA_TL_CODEC")
        if not executable:
            pytest.skip("native TL pending: compile fixtures/java_values/native_codec.swift with production TL codec/schema")
        run_child("native_codec", tmp_path, executable)
