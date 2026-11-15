# TLN-F01/F02 — validator source closure

2026-11-15. **Оба P2 — CLOSED-SOURCE. Новых P1/P2 в проверенной дельте не найдено.** Проверены только TLN-F01/F02 из `tl-network-source-closure.md`, их validators, отрицательные controls и SDK probe wiring.

Fix: `218f73272cef7eba3bb8cb23dc8bd959704b5a3c`. Текущий HEAD: `d8cbdaca17272ba848ac65be2b4dcbbc6b175275`. Прочитан верх `docs/wave-2/tl-review-remediation.md` и реальные applied sources. Статусы остальных TLN-01–11 не пересматривались; старые отчёты сохранены.

## TLN-F01 — optional peer-ID null

**CLOSED-SOURCE.** В `telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLTransformCodec.swift:308–329` объект с `.null` в declared peer role сначала проходит shipping schema codec. Для конструктора используется `normalize(as:)`, для method object — encode/decode request. Native role/range validation затем читает canonical fields.

Это закрывает исходный `updateShortMessage(flags:0, via_bot_id:null, message:"after")`: выключенный optional действительно отсутствует после normalization. Candidate по-прежнему проверяется до native parser; blanket разрешения для любого null нет. `response:104–114` возвращает canonical bytes, а `update:117–124` теперь нормализует candidate **до** reference-shape comparison.

**Проверенные controls:**

- `NativeFixtures.swift:343–354`: original short message → text edit; omitted и explicit null дают одинаковые bytes и текст `"after"`; inferred flags дают тот же результат.
- `:355–367`: enabled bit + null, required `user_id:null`, oversized peer ID, введённая nonnull reference и retarget `7→9` отвергаются.
- `:369–385`: тот же optional-presence случай проходит accepted `Update`; enabled null и nonnull retarget остаются запрещены.
- `TLCodec.swift:424–459,481–493` сохраняет authoritative masks, shared-bit companions и required-field checks. Например, `broadcast_id:null` с включённым общим bit не может пройти только потому, что это peer role.
- Диапазоны peer IDs сохранены в `TLTransformCodec.swift:252–261,327–346`; opaque document/random/access-hash Int64 не становятся peer IDs.

Дополнительный native XCTest `TelegramCore/Tests/ExteralessTLReviewTests.swift:89–134` передаёт принятые bytes настоящему `Api.parse`, проверяя `viaBotId == nil` и изменённый текст. Его наличие — source coverage; отдельный успешный запуск этого TelegramCore XCTest здесь не заявлен.

## TLN-F02 — counter-free RPC Vector mutation

**CLOSED-SOURCE.** `TLTransformCodec.swift:104–114` по-прежнему безусловно выполняет schema normalization, `preserveContinuity` и `preserveProtocolSubtrees`. Reference projection применяется при continuity либо state context исходного результата. `hasStateContext:131–139` рекурсивно распознаёт Update/Updates/State/Difference/ChannelDifference.

У обычного `Vector<User>` из `users.getUsers` нет принятого state snapshot: append `userEmpty(29)` к `[userEmpty(7)]` и последующее filtering теперь проходят shipping `response`. При этом отдельный `update(...)` всегда сохраняет references (`:117–124`). Production Network использует этот же validator между plugins и на final boundary, затем исходный `data.2.parse` (`TLNetworkRequest.swift:390–403`).

**Проверенные controls:**

- `NativeFixtures.swift:387–393`: User append и removal проходят **`ExteralessTLTransformCodec.response`**, затем binary decode сверяет ожидаемый vector.
- `:394–397`: Int vector append и точная Long mutation выше `2^53` проходят тот же путь.
- `:399–405`: `User.id = Int64.max` и retarget внутри counter-bearing Updates остаются rejected.
- `TLTransformCodec.swift:154–170,185–215` продолжает защищать protocol payloads, constructor/counter equality, добавление/удаление continuity subtrees и размеры counter vectors.
- `NativeFixtures.swift:280–301`: удаление/добавление encrypted operations, ciphertext edit и nested encrypted update отвергаются; unchanged encrypted payload проходит. Counter-free `messages.sentEncryptedMessage` всё ещё нельзя CANCEL. Protocol policy сохранена в `TLUpdatePolicy.swift:7–18,37–42`.

Native XCTest `ExteralessTLReviewTests.swift:136–155` дополнительно передаёт результат в **original generated method parsers** `users.getUsers`, `stories.readStories`, `messages.receivedQueue`; его runtime pass не выведен из standalone runner receipt.

### SDK probe теперь использует production policy

`python/runtime/smoke/swift_sdk_tl_probe.swift:280–301` захватывает original canonical payload, declared method result и фактическую metadata. Post replacement closure вызывает **`ExteralessTLTransformCodec.response`** (`:294–296`), а не только codec normalization. RPC-error replacement явно запрещён; fixture byte bounds сохранены.

Существующие post cases flags2/shared bot bits и User/Int/Long vectors проходят через этот closure (`:350–382`). Поэтому прежнее расхождение между probe oracle и shipping post policy устранено в source.

`tools/runtime/check_swift_plugin_embedding.py:373–391,424–427` включает `TLTransformCodec.swift` и `TLUpdatePolicy.swift` как в compile inputs, так и в `build-inputs.json`. Их включение не ограничивается fingerprint. Отдельные SDK children запускаются позже (`:430–467`); этот follow-up не объявляет их выполненными.

## Execution receipt и граница verdict

От координатора получен конкретный receipt: **Mac component run `43723262961`, commit `eb44fd9cd1b8264de11ed5b406a19ac488c6804a`: shipping TL native-fixture runner и Java7 — PASS.** Позднее падение Core test compilation на Darwin wait относится к последующему шагу; whole component run green не заявляется. Полный лог в этой сессии не читался, receipt атрибутирован координатору.

По source `NativeFixtures.main:145–150` действительно вызывает `reviewRegressions` и новый `optionalRolesAndPostVectors`; поэтому успешный standalone runner включает приведённые выше positive/negative assertions. `run_native_fixtures.py:24–30,42–49` компилирует shipping codec/validator/policy sources, включая нужный Hook ingress; compile budget — 120 s, execution budget — 28.5 s. Этот runner не запускает Account, Network, SDK loader или TelegramCore XCTest host.

Сравнение с `218f7327` и `eb44fd9c` подтвердило совпадение текущего текста validator, protocol policy, codec, native fixtures, двух новых XCTest методов и SDK probe/driver (с нормализацией line endings). Текущий standalone driver совпадает с **eb44**; после fix commit в нём был выделен общий `SOURCE_NAMES`. Applied `TLNetworkRequest.swift` проверен по отдельному working-tree pin.

**Full Swift/C/CPython SDK 3-child execution остаётся pending.** Два source defects закрыты; full app/native integration или более широкая parity этим отчётом не подтверждаются. Новые тесты, CI и live RPC/HTTP/account операции в этой сессии не запускались.

## Source pins

Raw SHA-256 текущих файлов без нормализации CRLF. Старые reports включены для проверки readonly boundary.

```text
95e740b878ba1c2f981e7d879484537937404036c3149bbeb623e3da0f752475  docs/wave-2/reviews/tl-network.md
f4a0b87b5b36176739a50881b3eb6d2d0b3560f57567542734d5c7f67c1cbbc5  docs/wave-2/reviews/tl-network-source-closure.md
b10e51bf1afd16ff84e912f97bd452086c04a8a340185daad340e0480f25f500  docs/wave-2/tl-review-remediation.md
f0ab5063dc60f776b728ba471d9e6d82311bc1c4d0c87c601961bf205e6f917f  python/runtime/smoke/swift_sdk_tl_probe.swift
14c865c86cd58ee31128a861aaf119ef9cf12a8b057f771bfc3883f7973ef336  telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLTransformCodec.swift
ba6ad1462fc5d1dfce5ddc3fd619178ff1c4b0b5a8a5bd57650a0ec5166f3b2b  telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLUpdatePolicy.swift
c22611ed58f5594e27e8087da14f272eabed38e5c5b8306049d224af9c710863  telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLCodec.swift
468aebbb567a665ce93d54f24e4e816c88519a48f3b1f228ad7e625597c5c9ab  telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLNetworkRequest.swift
4661dbad81af66436b10b93e860f1d63c484a264a32accf957872f3cd8b716db  telegram-ios/submodules/TelegramCore/Tests/ExteralessTLReviewTests.swift
4b67ac34ce795e08a897b8ab3c764c664994f72265971c5ad1cf09680ee4b3a2  telegram-ios/submodules/TelegramApi/swift_scheme.tl
3fd6893056238ac6d06dd75c99971211c1959da8ce30e7a80f4dc7cc60fc9801  tools/compat/tests/tl_bridge/NativeFixtures.swift
d232f4de6a654feea6644e7a51503b1e6913b78d540a59dd4bda7be2691073c0  tools/compat/tests/tl_bridge/run_native_fixtures.py
76ec0ffb815560d4813e07b8ce7ecb42cd4c958c1722766428503f7df706129a  tools/runtime/check_swift_plugin_embedding.py
```
