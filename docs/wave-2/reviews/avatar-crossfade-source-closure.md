# Avatar crossfade — ASC-01 source closure

**ASC-01 source-closed. В проверенном scope remaining P1/P2 не выявлено.**
Native fixture не исполнен; build/runtime и visual/frame acceptance остаются pending.

## Проверенный срез

**2026-11-15 13:50:59 UTC**, HEAD
`8d607287f3e2617f5f45250f0448f680fa95ea5a`. ImageNode, новый fixture,
BUILD/manifest и проверенные dispatcher/animation/Texture/SignalKit sources
совпадают с commit после CRLF-нормализации. Actual `AvatarNode.swift` содержит
рабочую AF-remediation и совпадает с `appearance-avatar-frozen.sha256`; verdict
относится к этой композиции. Пути далее относительно `telegram-ios/`.

## ASC-01: прежний контрпример и ownership

- **Active fade → reset.** `submodules/AvatarNode/Sources/AvatarNode.swift:995–1008,527–533`
  ведёт в `submodules/Display/Source/ImageNode.swift:226–242`. Уже созданные
  crossfade-слои (`:189–199`) теряют animations, bitmap и superlayer при clear.
  Ownership задан private final типом `ImageNodeTransitionLayer` (`:132–133,233`):
  foreign overlays сохраняются. `isNodeLoaded` guard позволяет обходить существующие
  sublayers без принудительной загрузки node.
- **Поздний completion.** `ImageNode.swift:197–199` захватывает weak-ссылку на
  исходный layer. Повторный/reentrant callback может удалить только этот объект;
  новый fade ему недоступен. `submodules/Display/Source/CAAnimationUtils.swift:19–28`
  дополнительно делает delegate completion одноразовым. Обход snapshot-массива
  sublayers остаётся корректным при удалении layer внутри completion.
- **Thread boundary.** Создание слоя доставляется на main через
  `ImageNode.swift:177–178`, `submodules/SSignalKit/SwiftSignalKit/Source/Signal_Dispatch.swift:3–24`
  и `submodules/Display/Source/DisplayLinkDispatcher.swift:14–18`. Clear синхронен
  в существующем main-thread contract: его первый super-вызов проверяет main
  (`submodules/AsyncDisplayKit/Source/ASDisplayNode.mm:3225–3237`). Cleanup завершён
  до возврата reset; отложенного обхода слоёв следующего renderer нет.

## Fixture и следующий gate

`submodules/AvatarNode/Tests/AvatarImageTransitionResetTests.swift:10–58` использует
actual AvatarNode/ImageNode и локальные UIKit bitmap. Две ValuePipe-эмиссии идут
после возврата `setSignal`, когда `wasSynchronous == false`. На main они исполняются
сразу (`submodules/SSignalKit/SwiftSignalKit/Source/Queue.swift:50–65`): fixture
проверяет установленную CAAnimation и старый bitmap **до** custom-letters reset.
Далее заданы assertions удаления contents/animations/superlayer, foreign-overlay
контроль, новый fade и ручной вызов сохранённого старого delegate. Уже завершённый
одноразовый delegate при таком повторе допускает no-op.

Подключение подтверждено: `submodules/AvatarNode/BUILD:35–63` содержит source и
Display dependency; `Tests/Exteraless/native-tests.json:73` отображает его в
`//submodules/AvatarNode:ExteralessAppearanceAvatarTests`, включённый в
`Tests/Exteraless/BUILD:238`.

Harness owner: native execution и запись перехода с labelled frames/ffprobe PTS.
Ожидание для кадров: после reset старый bitmap не перекрывает initials/новую
картинку; новый fade и посторонний overlay переживают старый completion.
В этой проверке выполнены только локальные source/pin checks; CI/network не использовались.
Код и три предыдущих review сохранены без изменений.

Raw SHA-256 ключевых sources:

```text
5ffc8f8a0ee816467f7c35d06cc1571691c8ddacc2be01eeae5453684e11f307 telegram-ios/submodules/Display/Source/ImageNode.swift
abd97a361a1d49cdf96523dc93aec215cda97b1da5ab347f028b9c3a343c017a telegram-ios/submodules/AvatarNode/Tests/AvatarImageTransitionResetTests.swift
a2a8c6e4b793f92327262b542ccd4a9e375eca926a8d405c1cd23235a887ecfd telegram-ios/submodules/AvatarNode/Sources/AvatarNode.swift
```
