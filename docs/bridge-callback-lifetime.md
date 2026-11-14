# Pending callbacks: Swift ↔ owner interpreter

## Постановка

`AndroidUtilities.runOnUIThread(runnable[, delayMs])` принимает tagged **положительный
Int64** handle Python-объекта. Владелец берётся из native interpreter state, не из
поля `pluginId` JSON-запроса.

Общий `BridgeServices` допускает максимум **256 pending постановок одного плагина**
и **1024 постановки всех плагинов**. Повторная постановка того же handle расходует
ещё одну единицу бюджета. Учёт: `(native pluginId, positive handle) → references`.
Численно одинаковые handles разных интерпретаторов независимы.

Проверка обоих лимитов, получение scheduler и увеличение счётчиков происходят
под одним `NSLock`, **до** вызова `onCallback`. Сам scheduler вызывается после
выхода из lock. Отсутствующий scheduler или исчерпанный бюджет возвращает
`ServiceUnavailable`; отказ не создаёт pending reference и не вызывает scheduler.

`onCallback(pluginId, handle, method, argsJSON, delayMs) -> Void` ставит работу
в очередь владельца. Swift не входит в Python из этого callback. Внутри него,
до Task/delay, снимается `host.callbackOwner(id:)`. Этот `PluginHost.CallbackOwner`
передаётся в `invokeCallback(..., expectedOwner:)`: token содержит identity хоста
и generation интерпретатора. После reload старый token получает `superseded`
до Python-вызова и не трогает accounting нового владельца. Координатор отменяет
отложенные Tasks ушедших поколений, освобождая их Swift closures.

## Завершение

Новый метод встроенного `exteraless.ios.Runtime`:

```json
{"op":"call","fqcn":"exteraless.ios.Runtime","member":"completeCallback","args":[77]}
```

`completeCallback(handle) -> Bool` принимает ровно один положительный Int64,
**число, не tagged object**. Доступен без `PluginPlatformService` и без scheduler.
`member_kind` возвращает `method`.

- Снимает ровно одну pending reference текущего native-владельца и освобождает
  одну единицу обоих бюджетов.
- **true**: это была последняя pending reference данного `(pluginId, handle)`.
- **false**: ссылки ещё остаются **либо** у этого владельца нет pending reference.
  В частности, native probe, вызывающий reusable handle без постановки, получает false.
- Повторное завершение неизвестного handle не меняет счётчики. Другие владельцы
  не затрагиваются. Нечисловой/нецелый аргумент — `MalformedRequest`, неположительный
  handle — `InvalidHandle`, отсутствующий native pluginId — `SecurityError`.

**Python handle этот метод не удаляет.** Owner runtime вызывает его в `finally`
после принятого callback; только при true выполняет `xt_release_handle(handle)`.
Обе операции выполняются подряд **под owner GIL**, без await, перепостановки или
выхода из owner-очереди между ними. Иначе новая постановка может попасть между
Swift-завершением и C-release. False не разрешает удаление reusable handle.

## Выгрузка и отказ до постановки

`BridgeServices.releaseInstances(pluginId:)` под тем же lock очищает pending учёт
владельца вместе с его отрицательными native handles и возвращает глобальный бюджет.
Повторная очистка идемпотентна. Координатор завершает старую owner-очередь до запуска
следующей жизни интерпретатора с тем же pluginId.

При отказе постановки callback не будет исполнен и его `finally` не наступит.
Транспорт откатывает **вновь экспортированные** Python handles неуспешного
вызова под owner GIL. Уже существующий/reusable handle нельзя безусловно освобождать:
у него могут быть другие pending references. Этот rollback не выполняется Swift-
счётчиками; `completeCallback` неизвестного handle возвращает false.

В C используется ledger каждой native call-транзакции: успешный вложенный
native вызов сохраняет принятые им handles при отказе внешнего вызова. Rollback
сохраняет исходное Python-исключение и не переиспользует ID. Смена test-realm и
bulk clear во время native call отвергаются, чтобы не потерять владельца ledger.
Debug-allocator probe проверил ошибки marshal/host, reentry из getter/destructor,
existing/negative handles и позднее completion на двух OWN_GIL workers.
