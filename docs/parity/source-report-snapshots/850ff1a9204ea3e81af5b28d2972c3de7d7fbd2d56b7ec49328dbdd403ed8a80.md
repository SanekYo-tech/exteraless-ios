# Full Telegram IPA — build 40 acceptance

**Независимый PASS: полный unsigned compile/package Telegram 13.1.1 (40).**
Run `43779402542`, commit `6de4ac36fefb54890a3dd043044e5a021a3d0e76`.
Проверен фактический полный IPA на Windows 2026-11-16.

**Файл:**
`build/artifacts/telegram-43779402542/release/Shared/telegram-ios/build/artifacts/Telegram.ipa`

Координатор подготовил побайтно идентичную delivery-копию:
`build/artifacts/telegram-43779402542/exteraless-ios-13.1.1-40-unsigned.ipa`.
Её размер и SHA-256 повторно совпали с проверенным оригиналом.

- Размер: **98 177 711 bytes**.
- SHA-256: **`e28940fdb017941525824ba1906d09e32da6bd973fa1c1c7c41bd294eeee3d99`**.
- Машинный receipt:
  [`local-verification.json`](../../build/artifacts/telegram-43779402542/local-verification.json).

## Download и provenance

Внешние GitHub ZIP сохранены в `build/artifacts/telegram-43779402542/outer/`.
Официальные artifact metadata независимо сверены по ID, имени, размеру, digest,
workflow run ID и head SHA. Оба артефакта относятся к указанным run/commit.

| Artifact | ID | ZIP bytes | Фактически вычисленный SHA-256 |
|---|---:|---:|---|
| `exteraless-ios-13.1.1-40` | 14187634135 | 273 790 711 | `03c89e65e136ab7ae8388b377097b0cdb296ca936d6a68ec0ed3d1665be969d6` |
| `unsigned-preflight-43779402542` | 14188291130 | 278 103 | `09879221a50f48da01c2df991dd6dc0981a105ca78cd9be149518bbcc60060dc` |

Размеры и digest точно совпали с GitHub. Загрузка выполнена двумя background
`gh api` командами с пределом процесса 110 s; stdout направлялся в binary file.
Auth/credential values не печатались и не включены в receipts. Максимальный
предел каждой shell-команды — 120 s. CI запуск/poll/build, установка, подпись,
плагины и Telegram account network не выполнялись. GitHub conclusion `success`
предоставлен координатором; статус run отдельно не опрашивался.

Outer ZIP, IPA, `Telegram.DSYMs.zip` и `Telegram_dossier.zip` прошли полное CRC
чтение и проверки имён. Traversal, duplicates, symlinks и encrypted ZIP entries
не обнаружены. Содержимое приложения не распаковывалось; encrypted package
credentials не декодировались и не выгружались.

## Фактическая структура приложения

`verify_ipa` из Git-версии `tools/ci/verify_unsigned_ipa.py` выполнен локально.
**Весь возвращённый результат равен CI `build-manifest.json`.**

- **2557 ZIP entries / 2467 regular files**, 226 502 125 uncompressed bytes.
- **1 Telegram app + 6 extensions + 60 frameworks**.
- Frameworks: **5 Telegram + 55 CPython/runtime**; runtime = Python + 54 extensions.
- Полная magic-census IPA нашла **67 Mach-O** — ровно заявленные executable files.
- Все **arm64, iOS platform 2, signing `none`**; ad-hoc/CMS/developer signatures,
  provisioning profiles и bundle resource signatures отсутствуют.
- Все declared executables существуют и имеют executable modes.
- У app и всех шести extensions версия **13.1.1**, build **40**.
  Main executable `Telegram`, platform `iPhoneOS`, minimum OS **15.0**.

Public bundle identity взят из committed
`telegram-ios/build-system/exteraless-configuration.json`; extension suffixes
сверены с Git `Telegram/BUILD`. Значения API credentials не проверялись/не раскрыты.

| Bundle | CFBundleIdentifier | CFBundleExecutable |
|---|---|---|
| Main | `ph.telegra.Telegraph` | `Telegram` |
| Share | `ph.telegra.Telegraph.Share` | `ShareExtension` |
| NotificationContent | `ph.telegra.Telegraph.NotificationContent` | `NotificationContentExtension` |
| NotificationService | `ph.telegra.Telegraph.NotificationService` | `NotificationServiceExtensionv1` |
| Intents | `ph.telegra.Telegraph.SiriIntents` | `IntentsExtension` |
| Widget | `ph.telegra.Telegraph.Widget` | `WidgetExtension` |
| BroadcastUpload | `ph.telegra.Telegraph.BroadcastUpload` | `BroadcastUploadExtension` |

## Load commands и runtime package

Pure `RuntimePackaging.verify_runtime_ipa` выполнен из Git blob указанного
коммита. **Весь результат равен CI `runtime-manifest.json`.**

- Main rpaths: `/usr/lib/swift`, `@executable_path/Frameworks`.
- TelegramUI имеет `@loader_path/..` и load `@rpath/Python.framework/Python`;
  main достигает TelegramUI и Python по разрешимым цепочкам.
- Python — relocatable dynamic framework с install name
  `@rpath/Python.framework/Python`.
- Все шесть extensions имеют `@executable_path/../../Frameworks`; все их
  dependency chains разрешаются. Python достижим из Share, NotificationContent,
  NotificationService и BroadcastUpload; из Intents/Widget — нет.
- TelegramCore не получил транзитивную CPython dependency. Проверены цепочки
  всех 54 Python extensions и все `.fwork`/`.origin` пары.
- Dynamic C bridge, build-only runtime framework headers/modules и дубли
  Python resources/frameworks в extensions отсутствуют.

**CPython 3.12.16** подтверждён не только строкой report: заново вычислен SHA
локального support archive
`4eea2c76ad70f2df8c1767489315a16d72cd96ce5c086412ee2d154c3bd8e257`,
сверен с Git lock и прочитан device `patchlevel.h`.
SHA всех **55 фактических runtime binaries** совпали как со staging inventory,
так и с соответствующими binaries этого pinned archive.
SHA embedded `Python.framework/Python`:
`b3482989a3f67680d930bfdddc776beefc4afb6c8bbc596a8252c639e0f168a3`.

## Source snapshot и Rust patch

Release/preflight `runtime-staging.json` побайтно идентичны:
`b3474ed89a27a291d4cfee0cf61f295c8f3e1de59e2be4e21425dc2aa94f2ea0`.
Идентичны и две копии `client-source-patches.json`.

Проверены **419/419 source hashes**: **416 raw Git blobs + 3 точных patched
postimages**. Использован binary `git cat-file --batch`, не current WIP и не
перекодированный текст `git show`. Дополнительно согласованы 248 compiler-source
hash records, 547 asset links, 857 device-resource links, 65 same-path Git assets,
renamed TL schema и 82 source pins bundled compatibility manifest (205 classes).

Rust provenance независимо восстановлен в памяти:

- Gitlink `telegram-ios/third-party/mtproto-engine` указывает на
  **`da4b2170210aab0430c4ff18c032991f3030cf45`**.
- Committed patch SHA:
  **`93ec3e78929a5ff22c85c04af8060fe447f446270e38bec06e2a34abd1a35366`**.
- Resolver postimage SHA:
  **`4c8b3fa7081f2ee23709b1e3df332fd3870c5781be1f931fd809c5acf40181d3`**.
- Пересчитанный source fingerprint:
  **`737ac0f2d1e9dd9b5b775095fdf84054a834b2ae8c371450fe2945536c678980`**.

Все три preimage/postimage hashes и размеры совпали с contract; применена его
точная CRLF map. Результат совпал с staging, runtime/preflight и clean-base
receipts. Рабочие Rust sources не изменялись.

CI preflight records: **12 631 actions, 12 packaging actions, 55 imported
framework actions**, errors = `[]`; native compile inputs — четыре C source,
Swift inputs включают реальный Host engine/binding, PluginHooks и ExteralessCore.
Это проверка сохранённых receipts; исходного Bazel action graph в артефакте нет.

### Bundled Config / compiler-root identity

Bundled `_config_manifest.py` побайтно равен Git `6de4ac36`:
`1554d2e49b665b19094245e91d42f3da1bb65859c284ead9f1a848292479395c`.
Проверены все **59 SOURCES pins**, **308 API / 508 bindings** и пересчитанные
**276 implemented / 0 blocked / 32 unsupported** из committed SDK receipt.

**Фактический raw root pin в этом IPA:**
`6d94c70b2b4e0f956365aa44a0dbafa60d1479eb734fbae6838afbf3ae943750` —
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift`.
Именно он совпал с Git, bundled `SOURCES` и SDK receipt. Root expression на
строке 55 содержит те же 21 группы. Его provenance находится в Config `SOURCES`,
а не отдельной строкой в 419-entry runtime staging source map.
Canonical inventory contract также пересчитан:
`37e50430c52002829a904ae102fbf1fd941aed8d6218272721e0360ab4c96c40`.

## Реальные assets и зависимости

По actual IPA проверены **1404 Python/stdlib files + 2 application resources =
1406 runtime-verifier resources**, дополнительно **12 native Font/Monet placements**.
Итого **1418 manifest-required resource placements**; missing/extra runtime
assets, неверных placements и дублированных pinned root resources — **0**.

- 856 stdlib files, один native-policy JSON и 547 runtime assets.
- Roboto Regular/Italic/OFL находятся в корне main, Share и NotificationContent:
  **9 placements**. Три Monet notices/licenses — в main root.
- Roboto не зарегистрирован через `UIAppFonts`, в соответствии с contract;
  оба фактически объявленных main `UIAppFonts` файла присутствуют.
- AdGuard rules и LICENSE — по одной копии в main root. Все Font/Monet/AdGuard
  bytes и размеры совпали с committed Git resource pins.

**12 distributions проверены по реальным bundled bytes**:
`packaging 26.3`, `requests 2.34.2`, `urllib3 2.8.0`, `idna 3.20`,
`certifi 2026.10.23`, `charset-normalizer 3.5.2`, `cachetools 8.0.0`,
`typing-extensions 4.16.0`, `beautifulsoup4 4.15.0`, `soupsieve 4.1.1`,
`pyyaml 6.0.3`, `debugpy 1.8.22`.

Все package metadata/archive pins совпали с Git lock. Перехэшированы
**479 payload files / 8 351 187 bytes**, плюс marker — sealed inventory **480**.
Bundle SHA:
`d7fe1f9be22ef7bf3bff75b5d462ebe756039c86226c56948007bed06aef8990`;
lock SHA:
`222da84eea828044f5af0e8d034945662fd74aae6414bc91f67d6311f14ef924`.

Additional native dependency frameworks/admitted packages — **0**. Bundled native
policy согласован со staging и committed lock; Pillow/lxml не заявлены как
OWN_GIL-admitted, debugpy упакован source-only. Проверка bytes не выполняет imports.

## Границы результата

Подтверждён **полный compile/package build 40** с указанным source snapshot.
Фактический `runtime_execution_verified` в release report — **false**.

Открыты отдельные gates: physical-device signing/install/launch, UI frames и
interactions/animations, APNs, live Telegram RPC/account operations, применение
responses/updates и новый **FD pipeline**.

Непубликованный DI helper, будущие **20SceneAcceptance** и новые **Host SDK
archive/trust** изменения не покрываются этим acceptance. Текущий working tree
не переименован в бинарный snapshot `6de4ac36`.

Старые receipts сохранены без изменений. Новые local receipt и документ содержат
только проверенные public identities, hashes и границы; auth/API credential
values и encrypted package credentials в них не включены.
