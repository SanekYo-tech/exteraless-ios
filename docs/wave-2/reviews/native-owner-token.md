# Независимое ревью C owner-token — 2026-11-15

Проверены `_exteraless_bridge.c`, `EXLPythonBridge.h`, `bridge_callback_probe.{c,h}`; `engine.c` — контекст границы вызова. HEAD `b274f4de`: перечисленные исходники в HEAD совпадают с baseline `68bb1adf`. В новом owner-token diff дефектов P0/P1/P2 не обнаружено. Ниже один воспроизведённый дефект существующей очистки handles.

## P2 — Reentrant bulk clear теряет новые handles

**Место:** `python/bridge/_exteraless_bridge.c:691–702`, особенно `695–701`; вызывается из `:3410` и `:3575` (`module_clear/free`). `realm_drop_entries` идентична baseline `68bb1adf`.

**Предусловие:** таблица держит последнюю ссылку на объект, чей `__del__` регистрирует другой объект во время `xt_clear_handles`.

**Причина:** DECREF выполняется до отсоединения массивов и обнуления размеров таблицы. Reentrant регистрация попадает в очищаемый массив. Для первых двух IDs новый слот находится раньше текущего индекса обхода и освобождается без DECREF объекта.

**Доказанный impact:** регистрация возвращает handle `2`, но после clear число handles равно нулю, release возвращает False, а weakref нового объекта остаётся жив после GC. Потерянная C-ссылка удерживает объект и его ресурсы без возможности штатного release.

**Исправление:** до первого DECREF перенести оба массива в локальный snapshot и сделать живую таблицу пустой; освобождать только snapshot, сохранив монотонный `next_handle`. Регистрации из finalizer должны учитываться в новой таблице либо явно отклоняться. При терминальном `module_clear/free` закрыть регистрацию до finalizers. Добавить regression bulk clear.

### Безопасный reproducer

Запущен на matching `.pyd`, Windows CPython 3.12.10, `PYTHONMALLOC=debug`. Код передан через `-c` отдельному процессу с `subprocess.run(..., timeout=8)`; `-B -X faulthandler`, `PYTHONDONTWRITEBYTECODE=1`.

```python
import gc, sys, weakref
sys.path.insert(0, r'C:\Users\sasha\AppData\Local\Temp\opencode\exteraless-native-owner-token')
import _exteraless_bridge as b
b.xt_set_plugin_id('review-clear')
b.xt_set_owner_token('review-epoch')
created = []
class Survivor: pass
class Retained:
    def __del__(self):
        value = Survivor()
        created.append((weakref.ref(value), b.xt_register_handle(value)))
value = Retained()
assert b.xt_register_handle(value) == 1
del value
b.xt_clear_handles()
gc.collect()
ref, handle = created[0]
print('new_handle', handle, 'count', b.xt_handle_count(),
      'release', b.xt_release_handle(handle), 'weakref_alive', ref() is not None)
```

Результат: `new_handle 2 count 0 release False weakref_alive True`, exit 0. Lookup потенциально освобождённого объекта не выполняется. Отдельный ранее выполненный случай с вложенным `xt_clear_handles` вызвал finalizer дважды. **Use-after-free/crash не подтверждены**; вывод о них был бы предположением. Доказанный finding — потеря владения и утечка. Дефект воспроизведён через explicit clear; воспроизведение через завершение интерпретатора не заявляется.

## Выполненные проверки и команды

- `git diff 68bb1adf HEAD -- python/bridge/_exteraless_bridge.c python/runtime/include/EXLPythonBridge.h python/runtime/smoke/bridge_callback_probe.c python/runtime/smoke/bridge_callback_probe.h python/runtime/engine.c` — пусто. Текущий diff прочитан полностью; отдельно программно сравнена `realm_drop_entries` с `git show 68bb1adf:python/bridge/_exteraless_bridge.c`.
- SHA-256 всех семи inputs совпали с существующим `exteraless-native-owner-token/source-fingerprint.json` до и после проверок. Исходник bridge: `17cf9a6532e361f347f19d201d91e95b2fe6f0f19384f2e4b508f112f949b6dd`.
- Повторно запущен существующий debug-allocator executable: `bridge-callback-probe.exe NUL C:\exteraless-ios\python C:\Users\sasha\AppData\Local\Programs\Python\Python312`, через `subprocess.run(..., timeout=20)`, с Python312 в PATH. Exit 0, `EXTERALESS_BRIDGE_CALLBACK_PROBE_OK`. SHA-256 executable: `df25f6c79df0d57e1faa64e7cbc2e077e271631c34cb97d2cb6997ed911469c0`. Новый report отправлен в NUL; числа **213 total / 169 baseline / 35 bound** прочитаны из существующего matching report, а не измерены повторно отдельным счётчиком.
- Собственный `python.exe -B -X faulthandler -c <in-memory unit>`, timeout 20: `REQUEST_CANONICALIZATION_REENTRY_OK 15 serialized envelopes`, exit 0. Перехват cached JSON serializer проверил уникальность top-level keys, immutable token, Unicode-subclasses, alias/hash collisions, input-dict snapshot при reentrant key destructor, сохранение nested context и owner после clear. Это проверка сериализации; native dispatcher в этом unit отсутствовал. Реальный dispatcher проверен предыдущей командой.
- Два exploratory clear cases и reproducer выше: отдельные процессы, timeout 8 каждый. Пересборка и изменения реализации не выполнялись.

## Покрытие и границы

- Проверены owned reference token и парные `Py_VISIT`/`Py_CLEAR`, exact-str копирование без Python equality hooks, UTF-8/NUL/256-byte validation, отсутствие global Python-token state, неизменённые OWN_GIL slots и `check_multi_interp_extensions=1`.
- Прослежены dispatcher acquire/detach/release вне mutex, counted-buffer lifetime и shared-claim rollback. Probe действительно проверяет native bytes token, parent/child isolation и маску всех семи bound операций; флаги отчёта обусловлены assertions и результатами workers.
- Probe проверяет reentrant destructor при rollback (`bridge_callback_probe.c:451–463`), но не bulk clear; поэтому зелёные 213 calls найденный дефект не исключают. Проверка одновременного drain нескольких активных callbacks с освобождённым GIL отдельно не выполнялась.
- Исполнение только Windows/CPython 3.12.10. Новые owner-token cases на iOS/macOS не проверены. Swift lease/coordinator, SDK phase 2 и итоговое ревью всего клиента находятся вне этого завершённого C-review.
