# Независимый follow-up C owner-token — 2026-11-15

**Исходный P2 закрыт:** безопасный reproducer теперь даёт `handle=2`, `count=1`, `release=True`, `weakref_alive=False`. Новых P1/P2 в проверенном исправлении не обнаружено.

**Ограничение:** полный fingerprint текущего дерева не совпадает с артефактом по двум Python-файлам. Независимый запуск всего 219-call/OWN_GIL/реального End probe остановлен до исполнения. Проверки `.pyd` ниже не импортируют эти файлы и подтверждают именно C-исправление.

## Проверенный snapshot

Прочитаны remediation note и фактический C/header/probe diff. Артефакты: `C:\Users\sasha\AppData\Local\Temp\opencode\exteraless-native-bulk-clear`.

- Все **15 native `.c/.h/.m/.modulemap` inputs** совпали с `full-source-fingerprint.json`; совпали оба бинарника и SHA старого ревью.
- Bridge C: `f9a94d4ed8cbaa7fae9e23f7b232313fa838a89c5407b60a603cebcea277f92a`.
- `.pyd`: `0a95124fbae6b045992b700d60690445dc42d72e68413c62d4736460cfc35f0f`.
- `.exe`: `cc1757d06af1e19b379399e9361a62fbb0b53dabf08423aac66782d365ec1415`.
- Старое ревью сохранено: `2c3938f5814133b9bf652a71b6697c552c2c2dc6a43bffec1a4cb18ec1835a52`.

Из полного набора **24 inputs совпали 22**:

| Несовпавший файл | Ожидался SHA-256 | Фактический SHA-256 |
|---|---|---|
| `python/virtualjava/proxy.py` | `938fc793c739b4762071cb46ad032c719de9c286abd46974de626c6b8bdb2a40` | `dbc949b9059a028ed395aaff1388afcae826a519d0eda9126a6838404059c2f2` |
| `tools/runtime/validate_runtime.py` | `0a144f2c550d872a620d92467ada66a910b23cbaf4a93b27c85b6231e1e51b01` | `0ba5f771490079bff7b0a9f7120cb0b7efd19d04ac50e413983343cf41c6f2f6` |

Fingerprint и исходники не менялись этим reviewer. Это ограничение воспроизводимости полного probe, не finding против параллельного Python/Swift WIP. Для его повторной приёмки нужен согласованный snapshot артефакта и всех inputs.

## Explicit clear: независимо подтверждено

- `python/bridge/_exteraless_bridge.c:702–725`: оба массива и capacity сохраняются локально, live pointers/counters обнуляются до DECREF. После finalizers функция освобождает только snapshot; `next_handle` сохраняется.
- Собственный исходный weakref-case выполнен на новом `.pyd`: **`SAFE_WEAKREF_OK 2 1 True False`**. Проверены liveness/count до release и смерть weakref после него; lookup старого/освобождённого объекта не выполнялся.
- Дополнительный отдельный процесс: nested clear, self-retention с новым ID и одним finalizer, регистрация 320 объектов из finalizer, смена realm и регистрация/удаление C service. **`DETACHED_NESTED_SELF_GROWTH_REALM_REGISTRY_OK`**, exit 0; новые объекты учтены и освобождены.

Минимальная проверка результата после прежнего reproducer из [первого ревью](native-owner-token.md), с import path заменённым на каталог нового артефакта:

```python
ref, handle = created[0]
count = b.xt_handle_count()
assert handle == 2 and count == 1 and ref() is not None
released = b.xt_release_handle(handle)
assert released is True and ref() is None and b.xt_handle_count() == 0
```

## Terminal clear и GC: независимая проверка

- `:417–424, :574–622, :3637–3665`: `closed` устанавливается до invalidation/DECREF; все state accessors проверяют его, включая captured module methods. Reentry получает builtin RuntimeError; повторный clear идемпотентен.
- В свежем main-interpreter процессе вызван настоящий `m_clear` через public `PyModule_GetDef` и `ctypes.PYFUNCTYPE` с удержанным GIL, вне native transaction. Finalizer попытался вызвать **27 entry paths**: все отклонены; новый payload не зарегистрирован, его weakref мёртв. Повторный clear и C `xt_host_release_handle` проверены: **`EXPLICIT_M_CLEAR_OK 27 rejected; payload weakref dead; C release rejected`**, exit 0. Это explicit module clear, не `Py_EndInterpreter`.
- `:2790–2823, :2853–2869`: traverse посещает implicit heap-type reference и три owned поля; dealloc делает GC untrack, clear, `tp_free`, DECREF типа. `gc.get_referents` подтвердил ровно одно type-edge для точного типа и Python-подкласса; 200 create/dealloc не изменили refcount типа, цикл подкласса собран. **`GC_TRACKING_HEAPTYPE_REFCOUNT_OK`**.
- Отдельно вызван backend `tp_clear` на живом объекте: повторный clear идемпотентен, поля исчезают из traverse, get/reinit отклонены: **`BACKEND_CLEAR_REENTRY_GUARD_OK`**.

## Реальный End: источник доказательства и границы

В существующем авторском `remediation-report.json`: **219 = 213 + 6** native calls, baseline 169; 27 terminal checks; **2 payloads created / 2 freed**. Это прочитанное авторское доказательство, не новый независимый прогон.

Проверен код `python/runtime/smoke/bridge_callback_probe.c:766–816, :911–929`: worker 1 принудительно очищает модуль и проверяет маску 27 отказов; worker 2 вызывает обычный engine destroy/`Py_EndInterpreter`. После End проверяются только native counters, по одному finalizer/attempt/created/freed на worker. Поэтому нулевое выполнение finalizer не может дать зелёный результат. Допущенная worker 2 регистрация до `m_clear` соответствует порядку GC finalizers; её payload обязан освободиться до возврата End. GC edge backend → heap type → module теперь видим сборщику.

## Команды и неизменённая граница

- Полный hash preflight через `python.exe -B -` выявил указанные несовпадения; `bridge-callback-probe.exe NUL C:\exteraless-ios\python <Python312-home>` **не запускался**.
- Два собственных in-memory unit запуска: `C:\Users\sasha\AppData\Local\Programs\Python\Python312\python.exe -B -X faulthandler -c <unit>`, каждый через `subprocess.run(..., timeout=20, capture_output=True)`, `PYTHONMALLOC=debug`, `PYTHONDONTWRITEBYTECODE=1`. Оба exit 0. Использован matching `.pyd`, импорт `virtualjava` отсутствует.
- Read-only сравнение с `git show HEAD:...` подтвердило неизменность dispatcher/buffer ABI implementation, acquire/release/decode boundary, shared transaction ledger, `engine.c` и `cpython312_compat.c`. OWN_GIL slots и `check_multi_interp_extensions=1` сохранены.
- Только Windows CPython 3.12.10. Реальный End нового snapshot, iOS/macOS, Swift coordinator/lease и весь клиент не получают независимый runtime-pass от этого follow-up. Старое отсутствие доказанного UAF/crash остаётся в силе.
