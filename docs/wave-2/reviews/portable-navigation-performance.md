# Portable navigation / performance — independent source review

2026-11-15. **3 новых P2, P1 не найдено.** Проверен applied working tree при HEAD `d8cbdaca17272ba848ac65be2b4dcbbc6b175275`. Прочитаны Telegram `AGENTS.md`/`CLAUDE.md`, три parity handoff и Subcodec `CLAUDE.md`; выводы основаны на actual sources.

Root binding, Core registration, Swipe shared/Cloud joins и performance ChatController callback действительно присутствуют. Исторические `pending` в handoff не выставляются findings. Финальные BUILD/SDK registry joins принадлежат owner.

Сокращения: `D/` = `telegram-ios/submodules/Display/Source/`; `U/` = `telegram-ios/submodules/TelegramUI/`; `K/` = `swift/ExteralessCore/`; `S/` = `telegram-ios/third-party/subcodec/`.

## PNP-01 · P2 — layout handoff теряет keyboard inset на regular width

**Места:** `D/Navigation/NavigationController.swift:648–678,1144–1148,1544–1547`; `D/Navigation/NavigationContainer.swift:655–683,700–711,1029–1035`.

**Контрпример:** уже показанный detail с `inputHeight = 500`, regular-width window, переключение Auto → Phone. Handoff уничтожает presentation state и передаёт сохранённый controller новому `NavigationContainer`. Тот обрабатывает его как новый pending push: `makeChild` получает `inputHeight = nil`, а `pending.value.layout.inputHeight == nil` включает `ignoreInputHeight` для regular width. Последний `applyLayout` этого прохода тоже доставляет **nil**, хотя root `validLayout` по-прежнему содержит 500. Это относится к обычному controller с пустым `disableAutomaticKeyboardHandling`, включая новый `LayoutModeController` fixture.

Сохранение first responder не исправляет этот layout: в конце handoff есть только условный `becomeFirstResponder`, без повторной доставки физического inset. При сохранившемся responder эта ветка вообще не выполняется. Экран получает неверную keyboard geometry до следующего layout/event.

**Fix:** отличать adoption сохранённого controller от первоначального push; передавать его актуальный keyboard layout и focus без начального обнуления. После восстановления responder согласовать layout с текущим root viewport, не ожидая нового keyboard notification.

**Test:** native regular-window fixture с настоящим first responder, выделением текста и keyboard inset; Auto → Phone → Tablet, immediate-ready и delayed-ready. Проверять доставленный inset, selection и ownership сразу после handoff. Нынешнее `telegram-ios/submodules/Display/Tests/AppearanceLayoutModeTests.swift:102–124` уже ожидает 500 на строке 121, что расходится с указанным source path; XCTest здесь не исполнялся.

## PNP-02 · P2 — новый elapsed clock вызывает неверные скачки source frames в DCT

**Места:** `U/Components/MultiAnimationRenderer/Sources/ToolsPerformanceRenderClock.swift:92–99`; `U/Components/DCTMultiAnimationRendererImpl/Sources/DCTMultiAnimationRendererImpl.swift:557–600`; фактический frame consumer — `U/Components/DCTAnimationCacheImpl/Sources/DCTAnimationCacheImpl.swift:692–710`.

Новый clock передаёт реальный, неравномерный elapsed в старую оптимизацию `advanceTimestamp / currentFrame.remainingDuration`. **Остаток одного кадра не является длительностью последующих кадров.**

**Контрпример:** равномерный source 60 fps, текущий остаток `1/60 s`; два tick по `15 ms` и `18⅓ ms`. Первый оставляет `1⅔ ms`, не декодируя кадр. Второй получает целый quotient **11** и запрашивает `.frames(11)`. Настоящий DCT cache вызывает `loadNextFrame()` одиннадцать раз; за суммарные `33⅓ ms` должны пройти два source frames. Это новая достижимость на обычном 60-fps source после замены фиксированного interval на elapsed, в том числе в Automatic.

**Fix:** один duration-aware учёт elapsed с сохранением остатка; не вычислять число кадров делением на остаток текущего кадра. Учитывать elapsed ровно один раз, включая время pending decode, сохраняя bounded catch-up.

**Test:** actual DCT renderer/cache seam с управляемыми ticks `15 ms + 18⅓ ms`, затем jittered 30/60-fps серии и задержанный decode. Проверять реальные frame indices/loop callbacks. `K/Tests/ExteralessCoreTests/ToolsPerformancePolicyTests.swift:186–201` проверяет другой planner, который DCT не вызывает.

## PNP-03 · P2 — Subcodec planner продвигается на N, настоящий источник — на один кадр

**Места:** `U/Components/SubcodecMultiAnimationRendererImpl/Sources/SubcodecMultiAnimationRendererImpl.swift:218–240,278–284`; `S/Sources/SubcodecObjC/SCMuxSurface.mm:116–129`; `S/src/mux_surface.cpp:407–414,428–432,458–466`.

**Контрпример:** Average, source 60 fps, tick `1/30 s`: Core возвращает `step.frames = 2`. Два вызова `advanceSprite` только дважды присваивают **один Bool `needs_emit = true`**. Единственный последующий `emitFrameIfNeeded` emits/advances ровно один source frame. Swift meanwhile прибавляет два к своему индексу. В результате реальная анимация остаётся примерно вдвое медленнее, а `didLoop` следует опережающему Swift счётчику.

**Fix:** выполнять необходимые schedule → emit rounds, декодируя зависимые P-frames и доставляя target только итоговый кадр; согласовать indices/durations/loop с реально emitted source frames. Простого повторения `advanceSprite` или изменения Swift index недостаточно.

**Test:** actual `SurfaceGroup` → `SCMuxSurface` → decoder на маленьком локальном sprite с различимыми кадрами, 30/60-fps ticks и пересечение loop boundary. Проверять decoded frame identity, а не только `step.index`. Существующий `S/Tests/SubcodecTests/MuxSurfaceTests.swift:1009–1010` правильно делает emit после каждого advance; новый adapter этот контракт не соблюдает.

## Source-closure по адаптерам

| Адаптер | Результат в проверенном scope |
|---|---|
| Layout | **Не закрыт: PNP-01.** Реальная root-role binding (`U/Sources/TelegramRootController.swift:114–115`), Auto stock path, raw 0…2, split/master ownership и bounded sheet geometry присутствуют. Retire обнуляет removal/filter callbacks, отменяет gesture, завершает coordinator и удаляет pending-ready ownership до reparent (`D/Navigation/NavigationContainer.swift:753–774`); отдельного late-pop контрпримера не найдено. Binding читает latest cache; reentrant mode request coalesces, applied-mode записывается отдельно. Hardware metrics не подменяются. |
| Chat swipe | **Source-closed; новых P1/P2 не найдено.** Projection использует только окончательный eligible set, сохраняет option/key/variant/destructive metadata, false mute и пустые наборы. Folders/Auto consult actual filters; row/pager используют общий arbiter. Final action остаётся в native `revealOptionSelected`, cancellation — в native motion path; дополнительного RTL inversion нет. Проверены `ChatListUI/Sources/Node/ChatListItem.swift:1074–1170,4059–4164,5823–5955`, pager `ChatListControllerNode.swift:548–581`, base `ItemListUI/Sources/Items/ItemListEditableItem.swift:395–455,515–545`. |
| Performance | **Не закрыт: PNP-02/03.** Native preferences отделены от effective projection (`U/Sources/SharedAccountContext.swift:565–585`); profile 0 сохраняет native flags, High не включает false. Power/battery/thermal/accessibility/background veto читаются из реального environment. DCT и Subcodec имеют decode/playback и delivery gates; caller-owned `shouldBeAnimating` сохранён. ChatController → message invalidation join применён (`U/Sources/ChatController.swift:6994–7003`; `ChatControllerNode.swift:4007–4019`). |

UI override не расширяет protected-data/network admission в рассмотренных joins: performance меняет копию energy flags и пересекает optional prefetch с native eligibility; остальные download/privacy поля сохраняются. Swipe Cloud импорт добавляет только точный `mainconfig.ChatSwipeAction`, сохраняя registered/non-secret validation (`K/Sources/ExteralessCore/CloudLegacySettingsArchive.swift:45–83`).

## Покрытие и evidence

- Layout: 4 Core + 5 native authored cases используют настоящий maker/containers, но draft-marker не проверяет UITextInput selection; reentrant A→B→A и keyboard-focus handoff отдельно не исполнены.
- Swipe: 5 policy + 2 actual Cloud preview/apply + 4 native authored cases. Native fixtures вызывают реальные option builders и UIView helpers, но не финальный gesture dispatch живого `ChatListItemNode`/pager; RTL, handler exact-once и live selector/filter changes ещё требуют native proof.
- Performance: 12 Core cases покрывают ограничения/публикации и pure planner. Новых native renderer tests на DCT/Subcodec actual path не найдено; именно эти seams пропускают PNP-02/03.
- Выполнен только read-only in-memory Python arithmetic/source probe, timeout **10 s**: DCT trace `remaining=0.001666666666666667 → frames(11)`; подтверждён mark-only body Subcodec `advance_sprite`. Это не Swift/UIKit/decoder execution.
- **Native build/execution и recorded frames остаются отдельным pending gate.** Известное исправление Mac Core-test wait `4aac68b3` не является finding адаптера. Accounts/network/CI/simulator не использовались; изменён только этот отчёт.

Контрольные raw SHA-256 проверенных counterexample sources:

```text
c92f5c4929ba566953bdb9869e527ac9b3ecff6ee253f256b65b2c7987f82b78  D/Navigation/NavigationController.swift
2807f5048216315735478a58c94a831f63dccba7d7f58e99feaea31c827bc108  D/Navigation/NavigationContainer.swift
51ec5574a96b0329e756ad3af90f87e6673fcb4b49970f07101056021083cefa  U/Components/DCTMultiAnimationRendererImpl/Sources/DCTMultiAnimationRendererImpl.swift
7d5482af7c1d97bfaf5ba231d404a1d844998158bf704d4640e7bbe5df2044b1  U/Components/SubcodecMultiAnimationRendererImpl/Sources/SubcodecMultiAnimationRendererImpl.swift
b7756bdb74bc364000cf3f674952ae5fad52581eba92704264f295f725d84dec  S/src/mux_surface.cpp
```
