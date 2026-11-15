# SDK06–09 — Java values / arrays / backed map views

2026-11-15. Source remediation applied. **CPython 3.12.10: 12 passed / 1 native-TL skip;
CPython 3.14.8: 11 passed / 2 native skips.** The 3.12 result includes the actual C
scalar/byte-marker transport. Foundation TL binary normalization is prepared and
**pending execution** on a host with Swift.

## Exact APIs and behavior

### SDK06 / SDK07: primitive descriptors and array identity

- `java.jbyte/jshort/jint/jlong/jfloat/jdouble/jboolean/jchar/jvoid` are stable
  interpreter-local converters with explicit descriptors `B/S/I/J/F/D/Z/C/V`.
  They retain plain Python scalar return values for arithmetic and the C codec.
  The integer converters retain range checks and `truncate=True` signed conversion.
- `java.jarray(component)` caches by the **canonical Java component descriptor**.
  Inputs include primitive converters, primitive names/descriptors, declared Java
  classes/FQCNs, and nested array classes/descriptors. Explicit compatibility aliases
  are `int→I`, `float→D`, `bool→Z`, `str→java.lang.String`, `object→java.lang.Object`.
  `jfloat` and `jdouble`, like `jint` and `jlong`, remain different components.
- Array classes expose `component_type`, `component_descriptor` and
  `_java_descriptor` (the whole array descriptor). Explicit FQCN strings retain their
  Java name even if the registry uses shared Python implementations. Class tokens
  use their declared `_fqcn` or native proxy name; scalar storage classes are not
  used to infer a converter's Java identity.
- `jclass("[I")`, `jclass("int[]")`, `jarray(jint)` resolve to one class;
  `jarray("[I")`, `jarray(jarray(jint))`, `jclass("[[I")` resolve to one nested class.
  `cast(array_class, value)` and array-name casts accept matching arrays and null;
  primitive components must match. Reference nulls, Object-array covariance and
  declared reference inheritance are supported. `Long[]` is not `Integer[]` despite
  the existing Python implementation inheritance. `void[]` is rejected by name.
- Length remains fixed, with the existing 1,000,000-element bound and atomic
  same-length slice validation. Primitive array elements cannot be null; newly
  allocated reference/nested arrays contain nulls.
- `exteraless_runtime._tl.to_wire` converts exactly Java `byte[]` to
  `{"__bytes__": base64}` using `item & 0xff`: `[-128,-1,0,127] → 80 ff 00 7f`.
  Empty arrays produce an empty marker. Recursive TL fields and `byte[][]` use the
  same branch. `int[]`, `long[]` and boxed `Integer[]` continue to produce arrays.
  `TLObject` serialization through `_codec` already delegates to `to_wire`.
- `finder.reset_class_cache()` explicitly resets the array cache for backend-reset
  tests; primitive converters remain stable. Two simultaneously live CPython child
  interpreters independently verify cache/primitive isolation on both Python versions.

`_tl.py` has exactly one four-line byte-array branch added. Removing those bytes
reproduces its pre-task SHA-256 `a237621adb7d10cf38a2887983a93d9b95ac3175487d9d33be78f25c3e690f25`.
Schema/root Vector/Boolean-mask/cancellation code is byte-identical to that snapshot.

### SDK08: boxed values, hashes and keys

- `Integer.equals` / `Long.equals` require the same boxed type and exact integer
  value. `Integer(1).equals(Long(1))` is false. Independent `Boolean` objects compare
  by Boolean value; its public `value` property is read-only.
- Java `hashCode`: Integer's signed Int32 value; Long's signed Int32
  `value XOR (value >>> 32)`; Boolean `1231/1237`. `Boolean.__hash__` matches its
  value equality. Integer/Long **Python** operators and `int.__hash__` remain intact:
  `Integer(1) == Long(1) == 1`, ordinary arithmetic and scalar codecs still work.
- `HashMap` / `LinkedHashMap` use private `_JavaKey` wrappers for non-string keys.
  Wrapper hashing uses Java `hashCode` with Java boxed equality, so Integer(1) and
  Long(1) coexist even when their hash codes collide. Original keys/values are
  returned by the public APIs; string-key dict storage remains C/JSON-compatible.
  `HashSet` uses the same key domain and retains set operations and Java iterator
  access. Explicit boxed keys are not inferred from unboxed Python numeric values.
- `put/get/containsKey/containsValue/remove`, constructors, `putAll/update`,
  subscript writes/deletes, `setdefault/pop/popitem/clear/copy/fromkeys` and mapping
  unions route through the key adapter. Null keys/values and old-value returns are
  preserved. Map/Entry Java equality/hash codes also use boxed value semantics.
- Native numeric unboxing remains `intValue()/longValue()/booleanValue()` or the
  existing int-subclass scalar path. Tests cover exact signed Int64 extrema and
  `9007199254740993` through the actual C marshal/unmarshal implementation.

Usage checked before choosing these semantics: original
`python/sdk/client_utils.py::_to_hash_map`,
`elyx_runtime/facade.py`'s HashMap construction,
`extera_utils/classes.py::_object_array`,
`extera_utils/plugin_loader.py`'s `jint(..., truncate=True)`, `ui/alert.py`, and
`file_utils.py`/`intents.py` key iteration. The existing port's
`ArrayList.remove(Integer(...))` relies on Python scalar equality to choose value
removal rather than the plain-int index overload; that behavior is tested.

### SDK09: backed views

- `HashMap.keySet()` and `entrySet()` are retained live views: length, iteration and
  membership observe subsequent puts/removes. `clear`, `remove`, `removeAll` and
  `retainAll` update the original map. Integer keys are removed as keys, not indices.
- `Entry.getKey/getValue/setValue` are backed; `setValue` returns the old value.
  Entry removal matches both key and value. Writing an entry whose key was removed
  raises `KeyError("HashMap.Entry.setValue: entry was removed")`.
- `keySet.add/addAll` and `entrySet.add/addAll` explicitly raise `TypeError` containing
  the complete method name. The earlier read-only `get(index)` convenience is retained.
- View/HashSet iterators support `hasNext/next/remove`, Python iteration and
  `StopIteration` on exhaustion. Remove requires one preceding next. Structural
  mutation, including remove+put at unchanged size, invalidates the iterator with
  `RuntimeError`; value overwrite and `Entry.setValue` do not. Iterator removal
  updates its own version and remains usable. General ArrayList iterators are unchanged.
- Python `keys/items/values` also remain live mapping views. Converting to a plain
  Python dict/set deliberately uses that container's own scalar equality domain;
  Java boxed-key identity is preserved in the Java collections.

## Executed checks

`tools/compat/tests/test_java_value_regressions.py` runs each case in a fresh
`-I -S -B` child with a **30-second external timeout**. Its fixtures are local schema
data and a small codec executable source; no plugin source or network is executed.
Optional native codec execution has an additional 20-second child limit.

| Final check | CPython 3.12.10 | CPython 3.14.8 |
|---|---|---|
| New Java regressions | 12 passed, 1 skipped, 2.72 s | 11 passed, 2 skipped, 2.73 s |
| Existing `test_virtualjava.py`, `test_sdk_tl_remediation.py`, `test_sdk_adapter_wave2.py` | 34 passed, 16.02 s | 34 passed, 17.83 s |

The existing SDK suite was read/run, not edited; its final count includes concurrently
added SDK-lead cases. Test plugin autoload was disabled with
`PYTEST_DISABLE_PLUGIN_AUTOLOAD=1`. Owned Python AST/whitespace checks and the
tracked finder `git diff --check` passed. No CI or commit was performed.

### Matching C execution

Explicit selected artifact:
`C:\Users\sasha\AppData\Local\Temp\opencode\exteraless-native-bulk-clear\_exteraless_bridge.cp312-win_amd64.pyd`.
SHA-256: `0a95124fbae6b045992b700d60690445dc42d72e68413c62d4736460cfc35f0f`.
Its adjacent `remediation-report.json` supplies the binary hash and compiled-input
fingerprint. The new child validates the ABI suffix, binary hash, bridge C and its
repository header before loading it. This extension links that C translation unit;
the larger historical 219-call executable/fingerprint is not reused as new evidence.

The C-owned echo service exercises real `BridgeBackend` marshal/unmarshal and
`xt_mock_log`: exact Long values read from distinct mixed-key entries, typed scalar
results, string-key HashMap transport, nested TL bytes markers, malformed-base64
rejection and Int64 overflow rejection. Completion leaves **zero handles**.

```powershell
$env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = '1'
$env:EXTERALESS_JAVA_BRIDGE = 'C:\Users\sasha\AppData\Local\Temp\opencode\exteraless-native-bulk-clear\_exteraless_bridge.cp312-win_amd64.pyd'
$env:EXTERALESS_JAVA_BRIDGE_RECEIPT = 'C:\Users\sasha\AppData\Local\Temp\opencode\exteraless-native-bulk-clear\remediation-report.json'
& 'C:\Users\sasha\AppData\Local\Programs\Python\Python312\python.exe' -X utf8 -B -m pytest tools/compat/tests/test_java_value_regressions.py -q -p no:cacheprovider
```

### Prepared Foundation TL control — pending

`tools/compat/tests/fixtures/java_values/native_codec.swift` consumes **actual Python
adapter output** from the optional test. Compile it with the production
`TLCodec.swift` and `TLSchemaGenerated.swift`; provide the executable as
`EXTERALESS_JAVA_TL_CODEC`, then run
`test_java_value_regressions.py::test_java_bytes_through_native_tl_codec`.
The binary verifies `sourceSHA256/nativeLayoutHash` against current Python metadata.

Seven cases: empty byte[], signed edge byte[], plain-bytes control, nested
`inputCheckPasswordSRP.A/M1` with exact large `srp_id`, rejected int[]/long[] in a
bytes field, and rejected malformed base64. Positive cases run real
`encodeRequest → decodeRequest`, including native-inferred flags; negative cases
must receive the production bytes-validation error. Native bytes validation was
not edited. Windows has no Swift compiler, so this remains an explicit execution gate.

Example bounded compilation from repo root on the Swift host:

```python
import subprocess
from pathlib import Path
codec = Path("telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime")
subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(codec / "TLCodec.swift"),
    str(codec / "TLSchemaGenerated.swift"),
    "tools/compat/tests/fixtures/java_values/native_codec.swift",
    "-o", "/absolute/scratch/java-values-codec"], check=True, timeout=30)
```

## Raw source freeze

SHA-256 over raw bytes, no newline normalization. This records the tested adapter
snapshot; subsequent source changes require an updated receipt.

```text
09088cce9b5d587eaecd57bdc9ddbed082ada60fa23308244577740510ab0c11  python/virtualjava/arrays.py
d1bc47eecc730b6b6ac9e724c3f957ffd9cb6b72a481c5f0cb0410704bb98e71  python/virtualjava/finder.py
30a1ed6fd51fef50587029ca692c1005067cad7ceba54a212163f50b4c314f56  python/exteraless_runtime/_java_types.py
6108bc28915113b7927696a11588f55fd4783c35f2238b108f6584d050801ba7  python/exteraless_runtime/_tl.py
a9c6b19357d0a637dd6f6c641198cd37552f317ac1202722291fde3a313fe6fb  python/exteraless_runtime/_codec.py
12675f1b9820b7890fefe34cd03bc5228bb5a7bba65424bc3644b6778341e164  tools/compat/tests/test_java_value_regressions.py
49b2d7dff4f02074f645d42089751d4f9b1d625cbc489f52f3e07241fea725a3  tools/compat/tests/fixtures/java_values/schema.json
c4799ff395a0707ad3b675b2bc51f2679cee280a27ba15ca3487bea1b86cb9cd  tools/compat/tests/fixtures/java_values/native_codec.swift
f9a94d4ed8cbaa7fae9e23f7b232313fa838a89c5407b60a603cebcea277f92a  python/bridge/_exteraless_bridge.c
6ecab9d92438e62bd3f0d7218f9646b78f9e3f764cc5d4e9f9e5a78b85b6166d  python/runtime/include/EXLPythonBridge.h
e02140d484cabcafbaa0545a017c5be9f6904c74ab0a9e74c3848af8b7ecd221  python/runtime/tl-schema.json
c22611ed58f5594e27e8087da14f272eabed38e5c5b8306049d224af9c710863  telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLCodec.swift
494428b67c12c23478afcd8f971959253703fee65e0bc3d8bc8a5ad101df0cf9  telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLSchemaGenerated.swift
```
