# Avatar source closure — AF-01…04

**Четыре исходных исправления подтверждены. Полная source-closure пока не дана:
остаётся один причинно связанный P2 — ASC-01 (active crossfade при reset).**
Других P1/P2 в проверенных четырёх сценариях не выявлено.
Apple execution, native fixture PASS и visual/frame acceptance не заявляются.

## Срез

Проверены актуальные исходники и AF-tail `appearance-remediation.md:167–275`.
В **2026-11-15 13:29:34 UTC** все **4/4** raw pins
`appearance-avatar-frozen.sha256` совпали. HEAD в конце чтения:
`8395d6be3d8fdc62035839c9c9d0adcad403d1e8`. Проверенные ImageNode/dispatcher,
Texture clear/suspend, SwiftSignalKit disposal/delivery и DirectMediaImageCache
совпали с этим commit по содержимому. Старые два review сохранены; реализация
не редактировалась. Ни CI, ни simulator/account/network не использовались.

Пути ниже относительно `telegram-ios/submodules`; `AvatarNode.swift`,
`PeerAvatar.swift`, `ExteralessAvatarShape.swift` — `AvatarNode/Sources/`.

| Контрпример | Проверка actual path |
|---|---|
| AF-01: parent raster → V2/reset | `AvatarNode.swift:807–820` suspend-ит реальный display layer, очищает parameters/contents, устанавливает `.image`, сбрасывает старый image source. `AsyncDisplayKit/Source/_ASDisplayLayer.mm:48–59` действительно отменяет pending draw. Font change не восстанавливает прежние parameters. Исходный parent-raster дефект устранён. |
| AF-02: round/roundedRect → bubble | V2 и resize вызывают общий final-clip API (`AvatarNode.swift:513–517,818–820`). `ExteralessAvatarShape.swift:50–73` сначала обнуляет radius для bubble, заменяет старый mask, переиспользует только свой named mask, обновляет его размер/bitmap без implicit tween; round/none снимают mask. Исходный double clip устранён. |
| AF-03: forum photo / placeholder | Account/Postbox wrappers делегируют одному complete-image compositor (`PeerAvatar.swift:93–135`). Единственный resolved style используется и decoder, и initials (`:145–175,215,420–441`); glyph clip сохраняется, caller font проходит в attributed string (`:477`). Full-size/blur и `.none` не теряют выбранный contour. Исходное расхождение regular/forum устранено. |
| AF-04: nil no-op / late old image | `clearImageSource` увеличивает generation **до** disposal и вызывает настоящий `ImageNode.clearContents()` (`AvatarNode.swift:527–533,995–1027`), а не `.single(nil)`. Cache next/completed проверяют generation; request-owned slot установлен до start (`:827–843`). Старый child subscriber прекращается при clear. Исходный nil/queued-result дефект устранён; остаток compositor lifetime — ASC-01. |

Late-delivery проверен в `SSignalKit/SwiftSignalKit/Source/`:
`Signal_Dispatch.swift:3–24` ставит
delivery на main; `Signal.swift:43–55` завершает subscriber при disposal;
`Subscriber.swift:114–123,152–162` отбрасывает его следующие значения.
`Display/Source/DisplayLinkDispatcher.swift:14–18` исполняет уже доставленный main
callback сразу, не держит дополнительную deferred очередь. V2 shipping adapter
действительно вызывает DirectMediaImageCache (`AvatarNode.swift:50–58,769–782`).

`overrideLetters` также сверён: forwarding `AvatarNode.swift:1450,1465`, выбор
массива `:872`, тот же массив в key `:923` и обоих draw parameters `:963,973`.
Отдельный layout-mode helper и другие Identity findings в этот verdict не входят.

## ASC-01 — P2: semantic reset не удаляет уже начавшийся ImageNode crossfade

**Место:** `AvatarNode.swift:527–533` →
`Display/Source/ImageNode.swift:186–195,222–227`;
base clear — `AsyncDisplayKit/Source/ASDisplayNode.mm:3225–3238`.

При второй асинхронной картинке ImageNode создаёт отдельный `tempLayer` с
**previousContents** и opacity-анимацией на 0.2s. `clearContents()` очищает основной
bitmap и subscription; его super также очищает только contents/placeholder.
Ни один из этих вызовов не удаляет `tempLayer` или его animation.

**Repro:** на реальном AvatarNode с включёнными image transitions доставить две
локальные PNG через legacy ImageNode и дать второй delivery создать crossfade.
До его completion переключить node в V2 либо custom letters. Parent/child model
contents уже сброшены правильно, но sublayer предыдущей картинки продолжает жить
до старого completion. По compositor path он может покрывать новый renderer на
оставшейся части fade. Это source counterexample, не наблюдение записанных кадров.

**Fix / native check:** semantic image reset должен отменять и удалять собственные
transition-image layers ImageNode. Добавить case с **уже установленным** crossfade
перед reset: после переключения нет layers/animations, удерживающих старый bitmap;
старый completion не затрагивает новый renderer. Проверять lifetime layers, затем
реальные frames переключения. Четыре новых fixtures ставят старые deliveries в
очередь **до** clear; это иной порядок. Их `render` использует model layer
(`AvatarNode/Tests/AppearanceAvatarRenderingTests.swift:321–328`), где tempLayer.opacity уже 0.

## Fixtures и доказательства

Прочитаны все четыре новые methods в
`AvatarNode/Tests/AppearanceAvatarRenderingTests.swift:130–312`: actual AvatarNode,
cached/local PNG decoder/compositor, cancellation и placeholder rendering.
Cache injection входит в тот же V2 path; отдельного fake renderer нет. Video plane
проверяет final clip, не AVPlayer. Fixtures **не исполнены**; нового test PASS нет.
Следующий native gate: эти cases плюс ASC-01, bounded execution после build;
visual acceptance — только по AGENTS labelled frames/ffprobe PTS.

Frozen source pins (raw SHA-256):

```text
a2a8c6e4b793f92327262b542ccd4a9e375eca926a8d405c1cd23235a887ecfd telegram-ios/submodules/AvatarNode/Sources/AvatarNode.swift
c6a5962a086ad151221c5e891bf6c32977e5a4697a00c89cc5492178692ca783 telegram-ios/submodules/AvatarNode/Sources/PeerAvatar.swift
18558f4c1cfc5208f8c83e9e75abbcf975554cacee55bcdbd2182869594a6dbc telegram-ios/submodules/AvatarNode/Sources/ExteralessAvatarShape.swift
321916d341d71675f9767eb85862f5f4e862597e7139f1acf78a0d14869df15c telegram-ios/submodules/AvatarNode/Tests/AppearanceAvatarRenderingTests.swift
46d65f25b002062f21c7b30c803a7a1b8318366848e8947842fd827fdf47887c telegram-ios/submodules/Display/Source/ImageNode.swift
a72039412ab3fc5e1efbc35636b26bb973ad095708872448a50d13c3329b4921 telegram-ios/submodules/AsyncDisplayKit/Source/ASDisplayNode.mm
```
