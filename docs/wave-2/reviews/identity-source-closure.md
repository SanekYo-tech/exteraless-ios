# Identity — source closure IDSF-01 / IDSF-02

**2026-11-15: оба findings закрыты по source. Новых P1/P2 в проверенных двух
путях не найдено.** Native typecheck, выполнение трёх новых fixtures и UIKit
frames остаются непроверенными.

## Срез

- Scope: только два remaining findings из
  `identity-dialogs-stickers-followup.md` и их реальные конечные consumers.
- Начальный HEAD `ffdb2833d68bbb7c0f51e684f109a494999a8e21`; source pin в
  **13:23:40 UTC** — `8c369a4bc1053eb9a509c1348ff2a95a0b42a61c`.
  Shared checkout изменялся другими owners; ниже зафиксированы raw-byte hashes.
- Прочитан последний раздел `identity-remediation.md`, новый Avatar delta,
  production contact composer, presentation bridge, consumer gates и три fixtures.
  Старое handoff-утверждение «Avatar patch awaits Appearance» уже не соответствует
  source: новый `overrideLetters` argument **применён и используется contact card**.
- Реализация и оба исходных reports read-only. Изменяется только этот файл.
  CI, network, реальные accounts и native tests здесь не запускались. Выполнены
  только read-only source/hash checks с 30-second outer bound.

Пути: **C** = `swift/ExteralessCore/Sources/ExteralessCore`,
**S** = `telegram-ios/submodules`, **N** = `S/TelegramCore/Sources`,
**U** = `S/TelegramUI`, **NT** = `telegram-ios/Tests/Exteraless`.

## IDSF-01 — CLOSED (source)

**Final name → initials:**
`N/ExteralessIdentity/ExteralessIdentityContactPresentation.swift:12–38`.

- Production account entry делегирует тому же snapshot composer, который вызывают
  fixtures. Foreign user/environment state отбрасывается. Alias ищется по
  **payload user ID**, независимо от наличия cached peer.
- Payload first/last name, alias и name order сначала compose; затем existing
  Zalgo filter применяется без прежнего early return для default/no-alias case.
  Fallback name также фильтруется (`:30–33`). Initials вычисляются из окончательного
  filtered name (`:38`), а не из raw contact fields.
- Для исходного no-peer counterexample `A` + четыре U+0301 / `B`, filter on,
  first-last, source path теперь даёт `A B` и `[A, B]`; last-first — `B A` и
  `[B, A]`. Off использует исходное display spelling. Stored payload/alias и
  cached peer не переписываются.

**Actual card consumers:**
`U/Components/Chat/ChatMessageContactBubbleContentNode/Sources/ChatMessageContactBubbleContentNode.swift:163–182,218–234,390,444–447`.

- Attributed title получает `namePresentation.name`; fallback branch использует
  тот же composer. Native title font/color продолжают назначаться в node.
- Обе avatar branches получают **один** `contactNamePresentation.initials`:
  no-peer — через `setCustomLetters`; associated-peer — через `overrideLetters`.
  `avatarPeer` — только исходный peer с совпадающим payload ID. Фото остаётся на
  native peer path, имя/initials не заимствуются из cached server name.

**Applied Avatar delta:**
`S/AvatarNode/Sources/AvatarNode.swift:854–872,923–924,963,973,1445–1474`.

Optional `overrideLetters` есть в обоих context-bearing `setPeer` layers и
передаётся outer → content node. Resolved `displayLetters` входит в
`AvatarNodeState.peerAvatar` comparison key и в оба has-image/no-image drawing
parameter paths. Следовательно, новый contact argument не теряется в forwarding
и не подменяется прежними raw peer initials. Default callers сохраняют свой
existing display filter; текущая Appearance geometry используется тем же путём.

## IDSF-02 — CLOSED (source)

Полная цепочка flag-only invalidation теперь присутствует:

1. `N/ExteralessIdentity/ExteralessIdentityPresentation.swift:17–22,37–62`
   наблюдает именно `privacy.zalgoFilter`. Effective Boolean сравнивается отдельно
   от `IdentityDisplayPolicy`, в одном serialized snapshot read. On/off/reset
   меняет revision даже при равной Identity policy; неизменный logical false
   deduplicates. После release lock публикуется существующая main-queue notification.
2. `S/TelegramPresentationData/Sources/ExteralessAppearanceUpdates.swift:8–32`
   устанавливает Identity observer до initial delivery и подписывается на эту
   notification. Initial emission читает актуальное состояние, поэтому запуск
   observer не зависит от первого последующего изменения peer/theme.
3. Production `PresentationData.swift:860` действительно возвращает этот bridge.
   `ExteralessAppearanceUpdates.swift:40–57` комбинирует latest native value с
   invalidation, создаёт свежую theme/cache identity и заново вызывает
   `currentDateTimeFormat`; `PresentationData.swift:208–211` включает новую
   `identityRevision`. Native/file-backed source не пересоздаётся этим display
   update; theme file read в добавленной ветке отсутствует.
4. Проверены реальные retained-consumer gates: `ChatListController.swift:472–477`
   → `ChatListNode.swift:3333–3344` заменяет presentation state; `ContactsController.swift:188–198`
   и `PeerInfoScreen.swift:6923–6938` принимают новую theme/date-format identity.
   Chat history также реагирует на свежую theme и публикует новые message
   presentation values (`U/Sources/ChatHistoryListNode.swift:2787–2804`), приводя
   к повторному contact-card composition. Peer write или unrelated clock event
   для запуска этой цепочки больше не требуется.

Этим устранена прежняя ситуация, когда formatter был правильным, но consumer не
получал apply. Filtered Avatar comparison/render fields проверены выше.

## Три native fixtures — source inspected, NOT EXECUTED

`NT/IdentityRemediationTests.swift`:

- **`:260–327`** — 48 combinations payload peer ID/cache/alias/order/filter,
  reset, filtered fallback и foreign-state rejection; asserts names/initials и
  сохранность raw inputs.
- **`:329–345`** — associated photo peer/representation сохраняется, title и
  initials берутся из contact payload; image fetch не вызывается.
- **`:353–449`** — shipping presentation stream с одним stable native value:
  initial false → true → false → true → reset false. Проверяются пять значений,
  revisions, свежая theme identity, один native subscription, no-op dedup,
  disposal и formatter/composer outputs. Main-queue drains ограничены 1 s.

Эти fixtures не исполнялись и не являются записью реальных controllers/avatar
drawing. Наличие assertions не обозначено как runtime PASS. Для frame acceptance
ожидается совместное обновление title/initials на retained list/profile/contact
после одного Zalgo toggle, с сохранением associated photo и native typography;
записанных indexed frames/ffprobe PTS для этого closure нет.

## SHA-256 pins

**19 paths**, 13:23:40 UTC. Aggregate:
`a71d2b48ae1f383fdf26c246a7891c5c477ccac23bbb29386aeae780a17c9cad`.
Формула: ordinal-sorted full repo-relative POSIX path + NUL + lowercase raw-file
SHA-256 + LF; затем SHA-256 UTF-8 конкатенации. Prefixes раскрываются перед сортировкой.
Большие shared files прочитаны только по относящимся к двум findings seams.

```text
a387b928e3bc337927c675bcd1bdbc5125c275b9f9b2ae6918ce8f249457e7e2  docs/wave-2/identity-followup-avatar-letters.patch
330625b687a339cd6ac3566f4728732e8ab3ede6fb8fbee3881e849f82ec6b4a  docs/wave-2/identity-remediation.md
7bf9a8bd2ec384c6ce67add8cff68df47f76796db9c4c5072cdfa081daa21087  docs/wave-2/reviews/identity-dialogs-stickers-followup.md
78a52ae89033c4d76574cc33d8127fe831c33c33e097a32a33762ffd49dcbeae  docs/wave-2/reviews/identity-dialogs-stickers.md
2546593c4319f96ee6efc16b04eb80b63991cabd7d99068bdd41c79a9365f690  C/FilteringTextPolicy.swift
06d6a564815c158f5d4bcd3eea65d245bbbf67a1c2f1fc88b2c6a561fd911e6e  C/IdentityPolicy.swift
747ad8bd2c84d6191df999c8745238613d8948148b70a25e2bc7161e61cde943  NT/IdentityRemediationTests.swift
a2a8c6e4b793f92327262b542ccd4a9e375eca926a8d405c1cd23235a887ecfd  S/AvatarNode/Sources/AvatarNode.swift
83d9d03a8a94e060cb2775e7249994a9dffbc58d83e119db2782927ed8889121  S/ChatListUI/Sources/ChatListController.swift
b0b219dc64342ba4ceb28300b8443984547906c535a77b7497cccb6f43ef634b  S/ChatListUI/Sources/Node/ChatListNode.swift
c3e1e6bee13295c7d7be27208783a145a0bbf2fb8369991fab3ae9f48e1bc4cd  S/ContactListUI/Sources/ContactsController.swift
7e6361a7231871e3b8d84058d0afc68130546f0c49eeeb10d13623f9965fac24  N/ExteralessIdentity/ExteralessIdentityContactPresentation.swift
8c62e66b1816c93d6945ad892e3b3f31e7aa06c1deb7974912bedb1c5ddd24ce  N/ExteralessIdentity/ExteralessIdentityPresentation.swift
a3c2b85e610e4ca6061790cae0fa3e5c0bad43d7bc2449f21934b15f3f61d190  N/ExteralessPrivacyExtras/ExteralessFilteringText.swift
099662fd1f7646dc1488ebaf1fccdea4e3cfa7ea4a26a37d8a28c6ce18bca6d2  S/TelegramPresentationData/Sources/ExteralessAppearanceUpdates.swift
f210596261c0ad92b0c6256bd5ef8be9fb40681d8b99c786c5f14c0480f9a6de  S/TelegramPresentationData/Sources/PresentationData.swift
5d926ac0bf6594f0b98505de77dabe404ddb2d6534c06452144c8b4480a09dbd  U/Components/Chat/ChatMessageContactBubbleContentNode/Sources/ChatMessageContactBubbleContentNode.swift
ecbedfd0769269b8907f6063bf557b4a8594c976c5904505d48c9de8802163ae  U/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift
f14dd23f146d6c1c77e29993206ff704ca692ee8b1d61247d97494e7b5a071e0  U/Sources/ChatHistoryListNode.swift
```
