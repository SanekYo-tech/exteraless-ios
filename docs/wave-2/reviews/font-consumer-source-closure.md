# PFM-01 — независимая проверка consumer source-closure

**PFM-01 CLOSED / source для трёх сообщённых потребителей. Остаточных P1/P2 в
этих контрпримерах и в companion-преобразовании не найдено.** Подтверждены ровно
**294 read-only getter replacements в 167 файлах**.

Срез: **2026-11-15 15:39 UTC**, опубликованный commit и текущий HEAD —
`2bac089c113dde061d86891e073ee08558a35d86`. Прочитаны PFM-section
`font-family-parity.md:284–435`, actual diff/source, три новые fixtures и
`font-family-global-cache-scan.json.application`. Проверка ограничена прежним
PFM-01 и семантикой process-global/static captures. Полная instance-cache/UI
closure этим verdict не устанавливается. Native fixtures и frame acceptance
остаются **pending**.

Пути ниже относительно `telegram-ios/submodules/`:

- **H** — `ListSectionHeaderNode/Sources/ListSectionHeaderNode.swift`.
- **A** — `ChatListUI/Sources/Node/ChatListArchiveInfoItem.swift`.
- **C** — `TelegramUI/Components/Chat/ChatMessageContactBubbleContentNode/Sources/ChatMessageContactBubbleContentNode.swift`.
- **T** — `telegram-ios/Tests/Exteraless/FontFamilyConsumerTests.swift` (от root).

## Три исходных контрпримера

| Потребитель | Проверенный actual path и результат |
|---|---|
| **Header** | **H:113–140** строит title/action из одного актуального `Font.regular(13)`. **H:143–165** проверяет UIFont identity и при `updateTheme`, и непосредственно перед измерением в `updateLayout`. Поэтому неизменные title/action/theme уже не пропускают смену family. Reset меняет ранее выбранный Roboto на текущий system font; новый node проходит тот же путь. Оба process-global UIFont удалены. |
| **Archive intro** | **A:96–117** разрешает regular 20/15pt **внутри каждого вызова** возвращённой layout closure, после выбора строк и до TextNode measurement. Захват `asyncLayout` до переключения не захватывает font. **A:206–244** повторно вызывает и применяет все три page layouts; header получает `updateLayout` безусловно на **A:257–262**, даже когда `themeUpdated == false`. Это покрывает прежний node/item/theme, новый node и reset. |
| **Contact title/body** | Production `asyncLayoutContent` получает `asyncLayoutContactText` на **C:109–113**, вызывает его при измерении на **C:249–252**, применяет к своим TextNodes на **C:418**. Semibold/regular 14pt запрашиваются внутри helper invocation (**C:91–105**), а не при захвате closure. При повторном запросе/new node/reset global font больше не участвует. |

Проверена нижняя граница cache: `Display/Source/ImmediateTextNode.swift:97–102`
передаёт текущий attributed text в настоящий TextNode layout/apply.
`Display/Source/TextNode.swift:2886–2909` сравнивает **полный attributed string**,
включая UIFont, и устанавливает полученный layout. Старое равенство строки или
theme identity не скрывает новый font на этих путях. Существующие immutable
attributed strings/layouts/CTLines не переписываются.

В contact refactor сохранены исходные ограничения 1/5 строк, truncation/alignment,
`maxTextWidth`, цвета и frame offsets `+7 / +1 / +20` (**C:95–104,247–252**).
Identity результат передаётся в новый stage после прежней обработки имени и
organization fallback (**C:181–237**). Initials/photo-peer routing по-прежнему
использует тот же `contactNamePresentation` (**C:408,458–461**). Изменения
сверены с parent diff; layout helper используется production, а не только тестом.

## Companion: точная семантика и postimages

Независимый read-only Python/stdlib probe, stdin, внешний timeout **30 s**;
успешный полный проход занял **0.356 s**:

- SHA-256 approved patch совпал с `application.approved_patch_sha256`.
- **167/167** текущих raw files совпали с `application.applied_hashes` и blobs
  опубликованного `2bac089c`.
- Reverse hunks применены **в памяти** к postimages. Все **167** восстановленных
  preimages совпали с `records.source_sha256` и blobs `2bac089c^`. Старые records
  не использовались как hashes текущего applied source.
- Проверены все **294** substitutions: **290 file-global + 4 static**. Access
  modifier/static scope, symbol и исходный `Font.*(...)` request сохранены;
  результат имеет строго форму `var name: UIFont { return <тот же request> }`,
  без setter, нового storage или иных действий. Остальные bytes совпали.
- Все requests используют исходные literal sizes и enum/trait arguments;
  скрытых вычисляемых аргументов/добавленных вызовов нет. Прямые UIKit/Display
  imports присутствуют; файл внутри самого Display использует свой `Font`.
- **36/36** исключённых declarations сохранены. Подтверждены exact counts
  `application.actual_count` и пустой `drift_files`.

Теперь **чтение getter** снова входит в тот же family-keyed Font factory вместо
возврата UIFont первого обращения. Размеры, веса, italic/tabular traits и роли
не меняются этим преобразованием. Четыре static getters находятся в
`QrStudioCodePillView.swift:106–107`, `QrStudioGlassButtonView.swift:90`,
`WalletWordSuggestionsComponent.swift:158`.

Этот результат относится к снятию process-wide capture. Он не доказывает, что
все instance-local text/image/measurement caches и content/color-only update
guards повторно читают getter. Ограничение из `font-family-parity.md:347–354,433–435`
остаётся в силе.

## Prepared native evidence

Прочитаны **T:112–225**, все три cases:

- Header: true → false → reset, прежний node, layout без переназначения
  title/action/theme, затем theme update и новый node.
- Archive: retained actual layout closure, прежний item/theme и новый node;
  наблюдаются шесть page TextNodes и настоящий section header, 20/15/13pt.
- Contact: retained **production** text-stage closure и новый contact node;
  наблюдаются собственные title/body TextNodes и frame offsets. Identity fixture
  использует snapshot overload, которому делегирует shipping account wrapper
  (`TelegramCore/Sources/ExteralessIdentity/ExteralessIdentityContactPresentation.swift:12–20`),
  а не альтернативный formatter.

Checks retained attributed text/UIFont/CTLine metrics находятся на **T:84–109**;
переключение/reset — **T:57–63**. Archive/contact retained closures в fixtures
создаются до первого layout. Native execution не заявляется, включая полный
account-bound `asyncLayoutContent`: его связь с tested stage проверена source.

Target уже подключён: `telegram-ios/Tests/Exteraless/BUILD:220–246,271`,
required-source binding — `native-tests.json:83`, `logic_seconds = 30` — `:10`.
Три fixtures **не запускались**. Source/hash checks не заменяют их native PASS.

Изменён только этот review; code, CI, network и frames не затрагивались.

## Raw SHA-256

Три consumers, fixture и две layout dependencies независимо совпали с
публикацией и working tree (дополнительный bounded probe: **0.046 s**).

```text
6f46246a6057c2294c3a007bdb2ec50134365661a21a59299b2fa76a84d2a26f H
17d1935a1841a38faee5694d1981225079fb9eff2bdbdb6c752c9e396f302735 A
d7acc310c6e6f7ecfdbde0050c0e7803dc777833d0bd4a6513573fc3de71e2ef C
579f05ce8fd17149478aa2ba4babefe31817b3f4439fa1b6c8c1edd2aadfcecb T
b11332320defd390cd3cc14ec5cf8fdca041ad104ae41c904da57887234c696b telegram-ios/submodules/Display/Source/TextNode.swift
6646c2c762e45efc8cde4e8190b3ea87724a4c58008aa3e7bee63c903522d1c5 telegram-ios/submodules/Display/Source/ImmediateTextNode.swift
30cf3c11ec28948992f22b399fc204f34713087fdf3cf5dd205f35b0153dfa3a docs/wave-2/font-family-global-cache-hunks.patch
a3e55a84e3f510100046b9b66b4b81a3b53539b073b175852588717c7d83357d docs/wave-2/font-family-global-cache-scan.json
```
