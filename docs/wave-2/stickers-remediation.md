# Stickers / Emoji — IDS-06, IDS-07, IDS-08 remediation

**Исправлены source-причины трёх P2. Native XCTest/CoreText execution и device
frames остаются непроверенными.** Исходный review
`reviews/identity-dialogs-stickers.md` сохранён без изменений, SHA-256:
`78a52ae89033c4d76574cc33d8127fe831c33c33e097a32a33762ffd49dcbeae`.

Базовый зелёный Core snapshot `e59bd30a8d89bebe4537bb0d9a391a118b2f3fa9` —
предоставленный контекст, не результат этой сессии. Новая исправленная cohort
зафиксирована ниже; её runtime acceptance не наследуется от e59.

## IDS-06 — fresh cloud recents перед local-only tail

- `StickerCollectionPolicy.recent` теперь проходит **cloud → local-only** с dedup
  по identity и применяет limit после этого порядка. Это исходный порядок
  `MediaDataController.java:2205–2233`, а не прежний ошибочный local-first oracle.
- `exteralessRecentStickerItems` вызывает настоящий native adapter
  `_internal_exteralessRecentStickerItems(postbox:policy:)`. Default/reset 20
  сохраняет native cloud-only projection; 21…200 добавляет local extras.
- Capture `exteralessRememberRecentSticker` включает текущий local send в начало
  authoritative cloud prefix явно: существующий sender вызывает capture **до**
  своего cloud-list add в той же transaction. Metadata свежего file выигрывает.
- `StickerCollectionPolicy.merged` сохраняет **отдельный local-first GIF shelf**.
  GIF adapter body байт-в-байт сохранён; его SHA-256:
  `c498e8460f38509a94b40ab6de447420386a501417186d6e2d0d795bf22ff1fd`.

Core tests исправлены: старое local-first утверждение больше не называется oracle
для recents; независимый GIF test закрепляет именно GIF-порядок.

Новые native cases в `TelegramCore/Tests/ExteralessStickerReviewTests.swift`:

1. Real in-memory Postbox + shipping view/decoder/policy adapter, local `1…200`,
   cloud `[999,1…19]`, limits **20/21/200** и fresh accessHash/fileReference.
2. Local-send fixture исполняет actual capture helper с изолированным ClientSettings
   и native ordered-list add в одной transaction. Remove/Clear вызывают существующие
   `_internal_removeRecentlyUsedSticker` / `_internal_clearRecentlyUsedStickers`.
   Account/sender network manager не создаётся.
3. Live subscription наблюдает reset 200→20, native cloud-only order и disposal.

## IDS-07 — serialized reread + publication

`ExteralessStickerSettings.swift`:

- Store callbacks передают только **invalidation**, без захваченного snapshot.
- `StickerPolicyDelivery` заново читает snapshot и вызывает `putNext` на одной
  dedicated serial queue. Store/observer/atomic lock не удерживается при subscriber.
- Используется **`justDispatch`**, а не `Queue.async`: последний выполняет closure
  inline на своей queue и позволил бы subscriber-triggered writes стать reentrant.
- Pending invalidations coalesce: не более одного ожидающего read помимо активного.
  Подписка ставится до initial read; disposal проверяется перед read и publication.
- Internal `didRead` seam используется только тестами для pause после настоящего
  чтения. Public API и production reader остались теми же.

Controlled native fixtures: writer A читает false и останавливается; writer B
коммитит true; после освобождения A итоговая policy **true**, без false после true.
Отдельно проверяются queued initial-read race, reset, disposal при остановленном
read и отсутствие reentrant publication при записи из subscriber. Settings store
при этом отдельный временный, не `ClientSettings.shared`.

## IDS-08 — cached visible decision для каждого используемого grapheme

Новый `Emoji/Sources/EmojiGraphemeSupport.swift` принадлежит одной immutable face:

- Cache включает positive **и negative** decisions, максимум **256 graphemes/face**,
  каждый не длиннее **32 UTF-16 units**. FIFO eviction выполняется под per-face lock.
- На cache miss формируется только запрошенный grapheme. Принимается один nonzero
  shaped glyph именно этой face, затем выполняется **96×96 RGBA CoreText bitmap
  probe** с предварительным clear и проверкой ненулевого alpha. Пустой glyph 2
  больше не получает разрешение от видимого glyph 1.
- Multi-glyph/partial ZWJ, modifier и flag composition консервативно получает
  whole-grapheme native fallback. Variation-selector acceptance требует явного
  default/non-default cmap-14 mapping; silently dropped VS не считается поддержкой.
  Cmap copy ограничен 1 MiB, record/group counts и binary-search accesses проверены.
- Нет whole-font atlas/simulation. Максимальный временный bitmap — 36 KiB.
  `font(for:)`, `attributedText` и preview используют одно `face.supports` decision.
  Installation probe проверяет только свои sample graphemes, не весь font.
- Attributed projector проверяет attachment/custom-emoji markers по **всему**
  grapheme range. Text/UTF-16, link, color/kern/underline и non-emoji font остаются
  исходными. Retained UIFont после reset/owner retirement имеет отдельный bitmap test.

**SFNT admission и source pins не ослаблялись.**
`EmojiFontInspection.swift`, `EmojiFontRegistration.swift`, `StickerFeatures.swift`
имеют пустой diff к e59. Original stored font bytes остаются прежними.

### Собственные pinned fixtures

| Fixture | Bytes | SHA-256 |
|---|---:|---|
| Original CC0 visible 😀 | 936 | `0e60fcc49115ab0bfc096118e3054a992f8b4fb917c0bdc601eda3e68dbfc5b7` |
| Review mixed: visible 😀 / nonzero blank 😉 | 968 | `3d8c2e9912be9ff1ffabee9f71feb51687b82d0f00535b1b22b20492736fd1ea` |
| Mixed + visible 👍 alias, absent tone mapping | 980 | `4361f295dc49f86262e9143620ec5489a5e933e6791caf8d3ed31aaffe5a8c67` |

968-byte fixture воспроизведена по report recipe: добавлен empty glyph 2, изменены
maxp/hhea/hmtx/loca/cmap-12 и checksums. SHA точно совпал с независимым report.
980-byte variant добавляет только U+1F44D→glyph 1 для настоящего partial `👍🏽` case.
Все три self-authored CC0; внешних assets/downloads нет.

`StickerEmojiRenderingTests.swift` получил **3 настоящих native tests**: bitmap
visible/blank distinction, частичные ZWJ/VS16/skin-tone + styles/UTF-16/link,
decision churn и retained old UIFont после reset/unregister. Это **поставленные
XCTest sources, не прошедший здесь CoreText run**.

## Выполненные checks

- `python -B docs/wave-2/tests/test_stickers_remediation.py -v` — **5/5**, 0.005 s.
  Проверяет source boundaries/cache budgets, actual adapter seams, immutable review,
  fixture SHA/table checksums/nonzero blank mapping и неизменный GIF body.
- Три актуальных contract checks (`exact_original_id_coverage_and_fragment_merge`,
  `fixture_is_pinned_licensed_sfnt_with_nonempty_emoji_glyph`,
  `boundaries_and_actual_native_consumers`) — **3/3**, 0.105 s.
- Официальный `python -B build-system/Make/PostboxImportCheck.py` — **exit 0**.
- Targeted `git diff --check` и newline/whitespace check десяти cohort files — pass.
- `swift`/`swiftc` отсутствуют. **Swift tests, native typecheck и frames не запускались.**
  CI, сеть/live accounts и external plugins не использовались.

Все native waits в новых controlled fixtures ограничены 1 s; нет sleep/polling,
Account construction или рабочего resource fetcher. Запускать адресные suites с
общим 30 s test-execution budget после сборки, отдельно от времени build.

### Build-owner insertion (не применён этим owner)

Новый file уже входит в `TelegramCoreTestsLib` glob. Для адресного native cohort:

```diff
*** Begin Patch
*** Update File: telegram-ios/submodules/TelegramCore/BUILD
@@
         "Tests/ExteralessRetentionTests.swift",
+        "Tests/ExteralessStickerReviewTests.swift",
         "Tests/PlayerSavedMusicTests.swift",
*** End Patch
```

`EmojiGraphemeSupport.swift` входит в существующий Emoji source glob;
`StickerEmojiRenderingTests` уже включает общий `EmojiFontFixture.swift`.
Новые production dependencies/allowlist entries не требуются.

## FROZEN — исправленная source cohort

**После этой фиксации cohort не расширять без нового согласования.**
4 Core source/test files + 6 native source/test files; shared picker, Tools
favorite writers, ClientSettings и независимый report сюда не включены.
Aggregate: sorted repo-relative POSIX path + NUL + lowercase raw-byte SHA + LF,
затем SHA-256:
`86d65bdd2ee974145aea43e74326939734a581fc66948c0c77de1dd898e78b11`.

```text
266f1e65ea2e2585407ac6fb6f019e5d5c9074589a8dfd9d1f38042d1f881350  swift/ExteralessCore/Sources/ExteralessCore/StickerPolicy.swift
0071b5c526a8b038eb6d140f3d507f38e4996bf1cbe5e7eb1fd94c973d49e403  swift/ExteralessCore/Tests/ExteralessCoreTests/EmojiFontFixture.swift
8d27976146aaa797c968a25d6bdd8ccf78a39e33e4ce7a345b4d35c0514c82f1  swift/ExteralessCore/Tests/ExteralessCoreTests/EmojiPackTests.swift
5551481502815229934d898e2c6fc8d2ee5934720a19ffb97094feeb6ffb10a5  swift/ExteralessCore/Tests/ExteralessCoreTests/StickerPolicyTests.swift
440254f93605b7f9a7381dd252edf1f1eb266510768598532f0950b7396a8cbf  telegram-ios/Tests/Exteraless/StickerEmojiRenderingTests.swift
47b46190e5afc1879f49c05fb3d194f1472e8f47309a829c5a76fb9fa45c124b  telegram-ios/submodules/Emoji/Sources/EmojiFontRendering.swift
7d70a3aa7274c06afe720dd658a9c34eb019081790decb61979fe8b38cdd1ff0  telegram-ios/submodules/Emoji/Sources/EmojiGraphemeSupport.swift
db9c780c0b0ee5747cbc6d032b3e96ce8279f3f65b5b7fee2318b6f2cd727937  telegram-ios/submodules/TelegramCore/Sources/ExteralessStickers/ExteralessStickerCollections.swift
14f3d0db44a2cf35149a48be1174077ff793db6b9f3803be1601151e2b11f3d6  telegram-ios/submodules/TelegramCore/Sources/ExteralessStickers/ExteralessStickerSettings.swift
a8f0b4b64901b92d5031d3fcf51dd288e3102ce69b8d1e057d83cbb58eb096ee  telegram-ios/submodules/TelegramCore/Tests/ExteralessStickerReviewTests.swift
```
