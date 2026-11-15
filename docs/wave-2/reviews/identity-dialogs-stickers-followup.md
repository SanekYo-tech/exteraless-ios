# Identity / Dialogs / Stickers — focused independent follow-up

**2026-11-15: 7 IDs закрыты по source; IDS-02 закрыт частично. Найдены два P2
на конечных Zalgo consumers/invalidation. Новых P1 не подтверждено.**
Source closure ниже не означает native typecheck, Postbox/CoreText/UIKit execution
или frame acceptance.

## Срез / execution attribution

- HEAD: `6f718b1108b9f90b5d498e07ee324325842bbe5d`; raw source pins сняты
  **11:51:47 UTC**. Прочитаны три remediation handoff и реальные timer, formatter,
  pin reconciliation, badge, recents, publication и glyph consumers/tests.
  Правила ранее прочитанных AGENTS.md/CLAUDE.md применены; старый review и Android
  остаются read-only. Изменяется только этот новый follow-up.
- **По сообщению пользователя**, `43708260304 / 7d04a35a` — PASS:
  **545 Core / 169 Host / 30 Hooks**, включая **9 Identity timer tests**.
  Локальный read-only `git diff 7d04a35a -- IdentityExpiryTimer.swift
  IdentityExpiryTimerTests.swift` пуст. Полный commit:
  `7d04a35a3612a2dc32dba6fb54744e38c07cabe9`.
- Четыре Sticker Core source/test files соответствуют `6f718b11`; CI этой cohort
  **pending по предоставленному контексту**. Все 10 hashes frozen Sticker handoff
  совпали. Ни `e59bd30a`, ни наличие test source не используются как evidence
  исполнения новых remediation tests. Native suites здесь не запускались.
- Выполнена одна in-memory проверка собственных 936/968/980-byte SFNT fixtures:
  SHA-256, table checksums, cmap/loca и visible/empty contour distinction;
  также проверены GIF body pin и неизменность старого report. Outer bound **30 s**,
  без сохранения fixtures. Это byte/source proof, **не CoreText rendering**.
  CI, сеть, live accounts, external plugins и загрузки fonts не использовались.
- Старый report по-прежнему имеет SHA-256
  `78a52ae89033c4d76574cc33d8127fe831c33c33e097a32a33762ffd49dcbeae`.

Пути: **C** = `swift/ExteralessCore/Sources/ExteralessCore`,
**CT** = `swift/ExteralessCore/Tests/ExteralessCoreTests`,
**S** = `telegram-ios/submodules`, **N** = `S/TelegramCore/Sources`,
**U** = `S/TelegramUI`, **NT** = `telegram-ios/Tests/Exteraless`,
**A** = `third_party/exteraless-android/TMessagesProj/src/main`.

## Per-ID source closure

| ID | Verdict | Проверенный source/result |
|---|---|---|
| IDS-01 | **Source closed**; 9 Core cases имеют приведённый выше CI context | `C/IdentityExpiryTimer.swift:31–72`: wakeup заново читает wall time, отменяет прежний timer, re-arms future deadline; boundary dedup и generation guard сохранены. Production lease действительно использует этот driver (`N/ExteralessIdentity/ExteralessIdentityPresentation.swift:68–113`). |
| IDS-02 | **Partial** | Account-bearing full/compact methods фильтруют окончательное composed name; attributed contacts и новые AvatarNode/PeerAvatar hunks применены. Contact-card fallback и live invalidation остаются дефектными: **IDSF-01/02** ниже. |
| IDS-03 | **Source closed** | Текущий-prefix heuristic заменён ledger sent order/local intent/generation/revision. Shared sync/replay вызывают его в реальных transaction boundaries; provisional unpin не является безусловным ignore. Подробности ниже. |
| IDS-04 | **Source closed** | Initial false входит в отдельную flag subscription; latest policy читается внутри Postbox transaction, persisted overflow/disable state инициирует coalesced reconciliation (`DialogIntegration:50–57`, `DialogPins:23–28`, `DialogPinReconciliation:128–148`). |
| IDS-05 | **Source closed** | Native seed tags, associated secret-chat contact identity, peer/global mute и root/archive eligibility определяются до subtraction. Excluded peer даёт 0 даже при unknown own count; messages/chats/manual mark согласованы с native accounting (`ExteralessDialogBadgeContribution.swift:8–36`). |
| IDS-06 | **Source closed**; corrected Core CI pending | `StickerCollectionPolicy.recent` проходит cloud → local-only tail. Production capture явно добавляет новый send перед ещё старым cloud prefix; view adapter использует этот новый порядок. Default/reset 20 остаётся cloud-only. |
| IDS-07 | **Source closed**; native execution pending | Invalidation не несёт snapshot; reread и `putNext` выполняются на одной serial queue. Именно `justDispatch` исключает inline reentry, pending coalesces, disposal проверяется до read/publication (`ExteralessStickerSettings.swift:13–62`). |
| IDS-08 | **Source closed**; CoreText execution pending | Каждый используемый grapheme проходит собственные same-face/nonzero/single-glyph и cleared bitmap checks; положительные/отрицательные decisions bounded и принадлежат immutable face (`EmojiGraphemeSupport.swift:19–64`). |

### IDS-01: time jumps, foreground и lease

- Старый пример wall=1000/until=1100/backward jump теперь заканчивается новым
  monotonic wakeup на оставшиеся wall seconds. Forward jump пересчитывает delay;
  after-expiry backward revival снова arms timer. Повторный identical deadline
  не сбрасывает `wasActive`, поэтому state dedup не поглощает unpublished expiry.
- `ExteralessIdentityIntegration.swift:23–35` вызывает refresh **всех retained
  leases** на foreground/significant-time-change; затем инвалидирует date labels.
  Callback — `Task @MainActor`, state delivery и shipping Timer — main queue.
- Driver проверяет cache lease перед schedule/publication; старый timer generation
  не входит после reschedule. Teardown вызывает `expiry.invalidate()` и token-aware
  `cache.end`. Retired lease не очищает новую publication того же account.
- `IdentityExpiryTimerTests` содержит 9 virtual-clock cases. Четыре native lease
  cases в `NT/IdentityRemediationTests.swift:46–149` используют настоящий
  lease/cache/projector и injected clocks. Они **ещё не исполнены**; UIKit
  notification delivery не проверяется одним вызовом `refreshExpiration()`.

### IDS-02: что уже исправлено и применено

- `S/LocalizedPeerData/Sources/PeerTitle.swift:8–26`: production account wrappers
  делегируют snapshot overloads; оба фильтруют `identity.name/compactName` после
  alias/order. No-alias/no-snapshot обычного user больше не обходит stock filter.
- `S/ContactsPeerItem/Sources/ContactsPeerItem.swift:968–999`: attributed filter
  стоит после alias и first/last font composition, до layout. Он сохраняет
  surviving UTF-16 attributes, не flatten-ит разные native fonts.
- Coordinator's **новые**, а не исторические, Avatar hunks присутствуют:
  `AvatarNode.swift:836–837,896,933,943` использует `displayLetters` в cache key
  и обеих has-image/no-image parameter branches. `PeerAvatar.swift:145–155`
  фильтрует initials перед drawing. Appearance clip policy остаётся в том же пути.
  `ChatListItem.swift:2052–2056` вызывает именно account-context overload.
- List/profile titles продолжают вызывать исправленный LocalizedPeerData formatter.
  Raw stored alias/server peer не переписывается. Три formatter/attributes cases
  `IdentityRemediationTests.swift:180–257` — native source, не прошедший XCTest.
  Они вызывают formatter заново вручную; это не проверка live invalidation или
  contact-message renderer.

### IDS-03/04: настоящий commit/echo порядок

- `N/ExteralessDialogs/ExteralessDialogPinReconciliation.swift:75–111` отличает
  native local intent по operation watermark, включая ABA; собственные replay/
  reconciliation enqueues фиксируют этот watermark (`:117–125`). Поиск actual
  callers подтвердил local pin/unpin/reorder и managed replay boundaries.
- `ManagedSynchronizePinnedChatsOperations.swift:85,119` передаёт реальный
  operation index. `:238–247` rechecks generation/revision/committed order перед
  применением read. `:294–315` записывает **encodedItemIds**, затем вызывает
  штатный RPC и признаёт только `.boolTrue`.
- Локальная перестановка `[1…6] → [6,1…5]` после old send не теряется от old unpin:
  replay сохраняет current intent и queues verification (`PinReconciliation:254–272`).
  Explicit local Unpin записывается в `intentRemoved`; old `.pin` не восстанавливает
  его. Unrelated remote additions не отбрасываются wholesale (`:164–180,246–252`).
- Обычный remote unpin после завершённого local intent проходит свежий authoritative
  read: `verificationPending` выбирает remote order; из отсутствующих IDs остаются
  только действительно local-only/secret pins. Это закрывает «ignore навсегда».
- Matching read использует **logical resolved order** в `appliedInCurrentTransaction`
  completion (`:206–234`). Проверен сам `Postbox.swift:2948–2977`: ranks прежних pins
  ещё не materialized до commit, поэтому преждевременный read-back здесь был бы
  неверным. Claim сохраняется до следующего begin: echo между response completion
  и отдельным native cleanup получает новую operation, не погибающую от old cleanup.
- A→B→off→A: при initial false A читает durable local-only/overflow, enqueues один
  необходимый read; повторный attach и covering in-flight generation его не
  дублируют. Authoritative false-mode reconciliation убирает overflow и очищает
  pending state; false/frozen result оставляет retryable intent.
- Девять cases `S/TelegramCore/Tests/ExteralessDialogReviewTests.swift:10–196`
  используют real disposable Postbox и отдельные committed transactions. Actual
  network/operation manager не создаётся; read/RPC responses injected. Эти native
  tests **unexecuted**, их source не доказывает работу server update scheduling.

### IDS-05: eligible contribution

`ExteralessDialogBackBadge.swift:21–58` наблюдает peer/contact/global notification
inputs; eligibility получает те же `includeTags`, что total. При exclusion own
summary вообще не нужна. Unknown included contribution/total скрывает number.
Старый initial scalar без provenance не показывается (`:8–12`).

Native classifier сверён с `SyncCore_StandaloneAccountTransaction.swift:52–83`,
mute resolver — с `Postbox/PeerNotificationSettings.swift:60–66`. Manual unread
при нулевом count даёт единицу согласно `ChatListIndexTable.swift:579–612`;
count-chats вычитает один eligible chat, count-messages — его eligible count.
Root-only total и existing root+archive privacy total не смешаны. Матрица tests
`:159–195` проверяет native totals/exclusion/mute/group scope, но пока не выполнена.

### IDS-06/07: recents и publication

- `N/State/SynchronizeRecentlyUsedMediaOperations.swift:40–46` вызывает capture
  **до** cloud add. Исправленный capture (`ExteralessStickerCollections.swift:33–40`)
  строит `[newFile] + oldCloud` как authoritative prefix. После cloud add в той же
  transaction view получает согласованный prefix; новый accessHash/reference
  выигрывает. Remove/Clear остаются на существующих native transaction paths.
- Source fixtures проверяют full tail 1…200, cloud `[999,1…19]`, local send 1000,
  20/21/200, reset, remove/clear. Actual shipping adapter принимает Postbox/policy
  (`:55–70`), не отдельный test-only merge. Core tests больше не называют local-first
  oracle для recents.
- **GIF не перенесён на recent policy.** `StickerPolicy.swift:80–94` оставляет
  local-first shelf; `exteralessSavedGifItems` body совпадает с handoff pin
  `c498e8460f38509a94b40ab6de447420386a501417186d6e2d0d795bf22ff1fd`.
- `StickerPolicyDelivery` читает свежую policy в queued closure и там же публикует.
  `Queue.swift:60–77` подтверждает разницу inline `async` / enqueued `justDispatch`.
  Subscriber-triggered settings write только queues следующий read, а не recursive
  emission. Coalescing оставляет максимум один ожидающий read помимо активного.
- Native controlled tests (`ExteralessStickerReviewTests.swift:79–180`) действительно
  приостанавливают **real read**, допускают independent writer B, затем проверяют
  final true, initial race, reset, disposal и reentry. Их execution pending.

### IDS-08: glyph decision / lifetime

- Positive и negative FIFO cache: **256 keys/face**, **≤32 UTF-16 units/key**.
  Per-face lock охватывает lookup/evaluation/eviction. На miss — только requested
  grapheme, один same-face shaped nonzero glyph и **96×96×4 = 36 KiB** bitmap,
  очищенный до `CTLineDraw`; ink другого probe не даёт поддержку пустому glyph.
- Partial/multi-glyph ZWJ/modifier/flag conservatively возвращает весь native
  grapheme. Для silently dropped variation selectors требуется explicit cmap-14
  mapping; проверены offset/count/range bounds и binary-search accesses. Retained
  cmap ограничен 1 MiB, admission/source SHA rules не ослаблены.
- `EmojiFontRendering.swift:137–170`: font, attributed text и preview используют
  один decision. Attachment/custom-emoji keys проверяются по **всему** grapheme
  range. Unsupported runs сохраняют исходные UIFont/attributes; поддержанные
  получают выбранную face с прежним point size. Text, UTF-16 и non-font attributes
  не переписываются.
- Content-hash registration и owner retirement сохранены. Failed unregister
  остаётся owned registry entry; retained UIFont имеет независимую жизнь от active
  selection. Native tests `StickerEmojiRenderingTests.swift:12–104,152–165` добавляют
  mixed empty/visible bitmap, partial sequences/styles и retained-font bitmap
  после reset/unregister. **Фактического CoreText результата/кадров здесь нет.**
- Независимый byte check подтвердил прежний 968-byte counterexample SHA
  `3d8c2e9912be9ff1ffabee9f71feb51687b82d0f00535b1b22b20492736fd1ea` и 980-byte
  thumb variant `4361f295dc49f86262e9143620ec5489a5e933e6791caf8d3ed31aaffe5a8c67`.

## IDSF-01 — P2: contact-card fallback и custom initials ещё обходят Zalgo filter

**Место:** `N/ExteralessIdentity/ExteralessIdentityPresentation.swift:201–205`;
`U/Components/Chat/ChatMessageContactBubbleContentNode/Sources/ChatMessageContactBubbleContentNode.swift:163–174,223–237,394–406,462–464`.

**Сценарий:** persisted `privacy.zalgoFilter=true`, default first-last, нет local
alias; получен contact payload с `peerId=nil`, firstName=`A` + четыре U+0301,
lastName=`B`. `exteralessIdentityContactName` возвращает nil **до** filter, потому
что alias отсутствует и order не last-first. Node оставляет raw `displayName`,
создаёт из него title и raw `customLetters`. Вызов `setCustomLetters` не проходит
через исправленные account-bearing AvatarNode hunks.

**Impact:** даже первое открытие card при уже включённом фильтре показывает
неочищенное имя/initials. При last-first helper очищает title, но custom initials
всё равно вычисляются из raw first/last. Это отдельный конечный путь, а не
неприменённый coordinator Avatar patch.

**Original proof:** `A/java/org/telegram/ui/Cells/ChatMessageCell.java:9212–9219`
форматирует именно contact payload через `ContactsController.formatName`;
`ContactsController.java:3119` выполняет `MessageHelper.zalgoFilter` после
composition. Rule на четыре marks — `MessageHelper.java:958–965`.

**Fix/test:** применить existing display filter после окончательного выбора
payload/local display name; согласованно получить display initials, включая
no-peer/custom-letters path. Сохранить raw contact payload и не подменять его
cached server name. Native contact-presentation fixture: no peer / associated
peer, alias absent/present/reset, first-last/last-first, filter on/off; проверить
передаваемые title/initials и неизменность payload. Текущие три name tests вызывают
LocalizedPeerData formatter, не эту ветку contact node.

## IDSF-02 — P2: изменение Zalgo preference не инвалидирует уже показанные Identity names

**Место:** `N/ExteralessIdentity/ExteralessIdentityPresentation.swift:16–20,36–44`;
`S/TelegramPresentationData/Sources/ExteralessAppearanceUpdates.swift:9–21`;
`N/ExteralessPrivacyExtras/ExteralessFiltering.swift:41–57`;
`S/ChatListUI/Sources/Node/ChatListNode.swift:2675–2685`.

**Сценарий:** открытый list/profile содержит неизменный peer/alias `A` + четыре
U+0301; presence не обновляется, app остаётся foreground. Изменить только
`privacy.zalgoFilter` false→true (или reset true→false), сохранив controller.
Исправленные formatter/cache-key работают при следующем вызове, но setting сам
такой вызов не инициирует:

- Identity observer допускает только `identity.*`; appearance presentation stream
  допускает только `appearance.*` и свои resource/identity notifications.
- Filtering runtime видит Zalgo key, но публикует свой отдельный `changes` signal.
  List реагирует на него, однако при выключенных sender/regex filters получает
  прежний list (`ExteralessFilteringSummaries.swift:180–182`). Ни dialog policy,
  ни raw peers/messages/presentationData не изменились; `forceAllUpdated=false`,
  equality entries не содержит Zalgo revision (`ChatListNodeEntries.swift:189–206`).
- Profile и Contacts title refresh зависят от theme/strings/date-format changes
  (`PeerInfoScreen.swift:6923–6938`, `ContactsController.swift:188–198`), а не от
  filtering signal. Эти presentation values от данного key не изменяются.

**Impact:** видимые/retained names и initials остаются в прежнем filter mode до
постороннего обновления. Новый `displayLetters` в AvatarNode comparison key
корректен, но не может обновить node, до которого не дошёл apply. Manual calls
в formatter XCTest не проверяют эту отсутствующую invalidation.

**Fix/test:** направить именно `privacy.zalgoFilter` в существующий cheap
presentation invalidation/revision path и обновлять конечные consumers без
изменения peers/aliases или theme file I/O. Простого расширения Identity observer
guard недостаточно: его `reloadDisplayPolicy()` не видит изменения Zalgo в
`IdentityDisplayPolicy` и оставит `changed=false`. Bounded native signal fixture:
один stable native PresentationData, flag on/off/reset, без peer/time/resource
events; после drain должны прийти display invalidation и обновлённые title/initials.
Отдельно проверить сохранённый profile и already-visible list row; frames pending.

## Оставшиеся evidence gates

- Закрыть IDSF-01/02, затем focused source follow-up для IDS-02. Остальные
  **source-closed** IDs не повышены до runtime/visual verified.
- Выполнить corrected Sticker Core CI и адресные native suites после сборки:
  `IdentityRemediationTests`, `ExteralessDialogReviewTests`,
  `ExteralessStickerReviewTests`, `StickerEmojiRenderingTests`. Предоставленный
  Identity Core PASS не подменяет эти runs.
- До записи ожидаемые frames: clock jump/foreground не оставляет expired badge;
  Zalgo on/off одновременно меняет titles и initials; late echo не удаляет новый
  pin, valid remote unpin завершается после verification; cloud recent 999 стоит
  первым; unsupported/blank emoji видим через native fallback; retained UIFont
  не теряет glyph после reset. Реальные indexed frames/ffprobe PTS по AGENTS.md
  ещё нужны. Source assertions и bitmap fixture bytes кадрами не являются.

## SHA-256 inspected-source manifest

**63 paths**, snapshot 11:51:47 UTC. Aggregate:
`5d7d6922e53e05e13e89a9a40607825a802033cddf46235f19d777eafaf6118a`.
Формула: ordinal-sorted full repo-relative POSIX path + NUL + lowercase raw-file
SHA-256 + LF; затем SHA-256 всей UTF-8 конкатенации. Prefixes раскрываются до
вычисления aggregate. Hash большого shared файла фиксирует прочитанные seams,
не заявляет повторное review всего этого файла.

```text
540077a9650310dd56f4260c1e4340df7fd4c354b2dbda6f7067b161d0a92172  docs/wave-2/dialogs-remediation.md
a9fb0c304cb3db6e5cb7b37180c26e48e1bf601416fee63e6f7cd93f278546f2  docs/wave-2/identity-remediation.md
78a52ae89033c4d76574cc33d8127fe831c33c33e097a32a33762ffd49dcbeae  docs/wave-2/reviews/identity-dialogs-stickers.md
ad1c01cc9f95ac885ab4af2f0a9e3f38e502b0ad43c8d203d5a451ece7fbbca8  docs/wave-2/stickers-remediation.md
f81ef717e723cbba7a9aff99dc28d108587d1f014dad7da1168f20c8d2843986  C/EmojiFontInspection.swift
179b5412b28b2d39d24ddeb80cfb1f2061f04c983b08d1a45ad542d23d985651  C/EmojiFontRegistration.swift
2546593c4319f96ee6efc16b04eb80b63991cabd7d99068bdd41c79a9365f690  C/FilteringTextPolicy.swift
9b135e55576fe5aa9afecd9fe3acbae98a12b6de22f970282de71c1fb22407de  C/IdentityExpiryTimer.swift
2f364e2ee3441fb902fdb18e126abc2c4285749c73e36604daa296ba1dca57a2  C/IdentityPresentationCache.swift
e5058ea295b09e5b8649496ca8e803405ee32f5d567291f165dfbd573be8242d  C/PrivacyExtrasFeatures.swift
266f1e65ea2e2585407ac6fb6f019e5d5c9074589a8dfd9d1f38042d1f881350  C/StickerPolicy.swift
0071b5c526a8b038eb6d140f3d507f38e4996bf1cbe5e7eb1fd94c973d49e403  CT/EmojiFontFixture.swift
8d27976146aaa797c968a25d6bdd8ccf78a39e33e4ce7a345b4d35c0514c82f1  CT/EmojiPackTests.swift
7524a6983b2b0d229d0cf861aa2dc56cc95e9306b1d9dbe3d7add5fad4b4b2b3  CT/IdentityExpiryTimerTests.swift
5551481502815229934d898e2c6fc8d2ee5934720a19ffb97094feeb6ffb10a5  CT/StickerPolicyTests.swift
43a8aa12ef70a45bd5f349028526a6ac50e170df4b5e8fcd30ec4547e192abc8  NT/IdentityRemediationTests.swift
440254f93605b7f9a7381dd252edf1f1eb266510768598532f0950b7396a8cbf  NT/StickerEmojiRenderingTests.swift
229c3a88cbfa8ef440893f70ec276258212942e1f1453a44989f43c40277fe0d  S/AvatarNode/Sources/AvatarNode.swift
403f43e74ce5d61856037f2a0b6562cc7544ca5a795eba9b54ac8f41354aecc9  S/AvatarNode/Sources/PeerAvatar.swift
5460b5ab8802973940afcca4964fc18bff1fd8421c36030a192ef634e6cfa110  S/ChatListUI/Sources/Node/ChatListItem.swift
b0b219dc64342ba4ceb28300b8443984547906c535a77b7497cccb6f43ef634b  S/ChatListUI/Sources/Node/ChatListNode.swift
699cab2124bf50d6eaa62f757f805d1e746568e18ed844f386b3bac52cfe88bb  S/ChatListUI/Sources/Node/ChatListNodeEntries.swift
8628c0275e8052bde1ebbd3e2d9e33b71caf06cbe818a25872d5fb2bb5e84901  S/ChatListUI/Sources/Node/ChatListNodeLocation.swift
7b425269efdafd9f803112053b81f676116b924dbab0b46e527e873bcd268d72  S/ChatListUI/Sources/Node/ChatListViewTransition.swift
c3e1e6bee13295c7d7be27208783a145a0bbf2fb8369991fab3ae9f48e1bc4cd  S/ContactListUI/Sources/ContactsController.swift
ad554b18512452b46b08eeecab29afed0b437e89ad301440870f448333365b70  S/ContactsPeerItem/Sources/ContactsPeerItem.swift
47b46190e5afc1879f49c05fb3d194f1472e8f47309a829c5a76fb9fa45c124b  S/Emoji/Sources/EmojiFontRendering.swift
7d70a3aa7274c06afe720dd658a9c34eb019081790decb61979fe8b38cdd1ff0  S/Emoji/Sources/EmojiGraphemeSupport.swift
e5765147b2a6b0033dcbcd1a8cef08a7c69d88baa2fb5c7b3920c255efb458c3  S/LocalizedPeerData/Sources/PeerTitle.swift
8a21b46fab8d02cfe00227aa9264a0ac26b6b703d2facfea8a76462ce8e2f6c6  S/Postbox/Sources/ChatListIndexTable.swift
04855ab99fddc45f80e8d3a56d755a655384cfbe0f782a2a9ad8aed5f2d7ca54  S/Postbox/Sources/PeerNotificationSettings.swift
70122e748ef0e5ac058c781ecb0f7825b82568f6757d946cab0ea47a78151341  S/Postbox/Sources/PeerOperationLogTable.swift
3209b384dc3a39cf4b1c69a4f2b51c147b2a19cf2c247203900bb55d696b1165  S/Postbox/Sources/Postbox.swift
ac7db4cdf6b9728f0936bf35998cee3f6b8d7824abbc07e71e679e068315b31b  S/SSignalKit/SwiftSignalKit/Source/Queue.swift
08630c786e0410459543d7cc2d56a02228345f4bb4996bcc4a79ce569b04474c  S/SSignalKit/SwiftSignalKit/Source/Timer.swift
828cefc3945dce036d0ec7d873c166926420748d36825d6679c4aa1a654f1dd1  N/ExteralessDialogs/ExteralessDialogBadgeContribution.swift
b00edc88a828bd79669d5073099b2f8afe6ec0f957766cdac720745d8d636d85  N/ExteralessDialogs/ExteralessDialogPinReconciliation.swift
ccde754b5ee2655edd75050bd48c348f571707ee467066035ea2b1ac6aca478b  N/ExteralessDialogs/ExteralessDialogPins.swift
afeb1e1c6034a29e082a479db806a968977f97e3e37e12771dc02c77d8ae7402  N/ExteralessIdentity/ExteralessIdentityPresentation.swift
88443fcff9e3caec1368ee77388bbfcb747f1ffec2727c00868dfd9c2ce535c0  N/ExteralessPrivacyExtras/ExteralessFiltering.swift
ee8cfa2eaaea636740dee2c20136452bef733366ed0fcbf286e9f576faf8805c  N/ExteralessPrivacyExtras/ExteralessFilteringSummaries.swift
a3c2b85e610e4ca6061790cae0fa3e5c0bad43d7bc2449f21934b15f3f61d190  N/ExteralessPrivacyExtras/ExteralessFilteringText.swift
db9c780c0b0ee5747cbc6d032b3e96ce8279f3f65b5b7fee2318b6f2cd727937  N/ExteralessStickers/ExteralessStickerCollections.swift
14f3d0db44a2cf35149a48be1174077ff793db6b9f3803be1601151e2b11f3d6  N/ExteralessStickers/ExteralessStickerSettings.swift
e1d90676635a725423178be2397d57bc364da2d417e53d3da295136488260ebc  N/State/AccountStateManagementUtils.swift
e3a3bfc467523d352ddc03cd02dbf6b4c3ca38ba734cf3cf53987863730a2708  N/State/ManagedSynchronizePinnedChatsOperations.swift
41cdcb7919b6c7fa675d1edf773559576449b0f79e0615b7dfd65b7489c044d1  N/State/SynchronizeRecentlyUsedMediaOperations.swift
acc8b85b6bbe24a41b5bf5e5872f0db3dfe81f1a563bcc4ba681a75504977597  N/SyncCore/SyncCore_StandaloneAccountTransaction.swift
f71d35af6ddbd9e9704d78ab84c82f55f02d341bb8458360875eadaf20decfc5  N/SyncCore/SyncCore_SynchronizePinnedChatsOperation.swift
4422c86b1df2d4e2cd5e0beb03ce3eaa66796328399dcddff3360abb4f2e1446  N/TelegramEngine/Peers/TogglePeerChatPinned.swift
f50f28d41c043a9450c1fffd3a81ccb094373bc7a51bf5394155655f5b1bb404  S/TelegramCore/Tests/ExteralessDialogReviewTests.swift
a8f0b4b64901b92d5031d3fcf51dd288e3102ce69b8d1e057d83cbb58eb096ee  S/TelegramCore/Tests/ExteralessStickerReviewTests.swift
a746d3354fb0fded57fb9ecd67bf186ea7bd890c77c52cd944211dae0a5fe36e  S/TelegramPresentationData/Sources/ExteralessAppearanceUpdates.swift
18f00717d9844369f45ae1fb964e8de37c7decf18b380583938cad4b06ff846a  U/Components/Chat/ChatMessageContactBubbleContentNode/Sources/ChatMessageContactBubbleContentNode.swift
2d3e959c505b31a5c240b71a1508761273a955470080fa33a1be7272fdc34992  U/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift
ecbedfd0769269b8907f6063bf557b4a8594c976c5904505d48c9de8802163ae  U/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift
488be2cb30b181cf91b4c4992b170cc6a43721d90bf09ea5d24056401238938b  U/Sources/ExteralessClient/Dialogs/ExteralessDialogBackBadge.swift
c5a01fcabcbc32b5e1f4e01956ee2f6bbaad58811554f45b2542351e849b2120  U/Sources/ExteralessClient/Dialogs/ExteralessDialogIntegration.swift
68bf0031a8f309251776610c36e782bb53a5674aa8449756272104b43c6a86b1  U/Sources/ExteralessClient/ExteralessClientRuntime.swift
e63e2fba957c20cd8262b4d6ff67201b115cf3e25c33911fb5ab52120552df84  U/Sources/ExteralessClient/Identity/ExteralessIdentityIntegration.swift
9ca5fa402d9715a96727002c2456fa74c45e5f29bb493bb2660bca8d7e5a3981  A/java/org/telegram/messenger/ContactsController.java
01be97e8c0947ebe10d4c0a43ffffd70fb8e5a6f9a6b4c8bbd98a4c35b8f233d  A/java/org/telegram/ui/Cells/ChatMessageCell.java
bc9b288acbbbed19dc37a9730e8b3d75d35d853164f41342f8e22985467f6db3  A/java/tw/nekomimi/nekogram/helpers/MessageHelper.java
```
