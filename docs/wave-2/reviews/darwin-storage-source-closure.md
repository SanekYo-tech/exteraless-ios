# Darwin storage root trust — source closure

**CLOSED на уровне source. Remaining P1/P2 в пятифайловом изменении: нет.**
Проверены допуск документированных OS aliases, отказ caller-controlled redirects
и сохранение прежних TBF ownership/transaction boundaries. Mac rerun остаётся
execution gate, а не условием этого source-вывода.

## Срез и основание

- **`96bff39e89dc889d410821242139d78339c70185`**, при чтении `HEAD -> main`,
  `origin/main`. Scoped diff пяти production files и нового test file относительно
  этого SHA пуст. Прочитаны commit diff, actual source и
  `darwin-storage-remediation.md`.
- Предоставленный failing Mac run **43728873627 / 46393e31**: Core compiled,
  663 tests, 42 error records / 35 failed methods; filesystem часть — **41 records
  / 34 methods**. Это pre-fix evidence. Отдельная AI surrogate ошибка не входит
  в рассматриваемое изменение.
- CI, Swift/Mac execution, пользовательские файлы и сеть здесь не использовались.
  Собственные fixtures не запускались. Старые reports сохранены read-only.

Далее пути production files относительны
`swift/ExteralessCore/Sources/ExteralessCore/`.

## Проверенные границы

| Граница | Source evidence / результат |
|---|---|
| **Valid OS aliases — CLOSED** | `ToolsFileSafety.swift:54–70`, `ToolsFileDescriptors.swift:133–178,370–395`: lexical spelling заменяется только для root `/var`, `/tmp`, `/etc`. До преобразования проверяется исходный URL. Production pin создаётся от fd, открытого для `/`; требуются symlink metadata, точный `private/<name>` либо `/private/<name>` target и равенство prefix-following `fstatat` с удержанным target inode. `/private/...` проходит непосредственно через no-follow walk. Прежнее сравнение разных допустимых Foundation spellings удалено. |
| **Custom descendant symlinks — CLOSED** | Исключение выбирается только по первому компоненту от filesystem root (`ToolsFileDescriptors.swift:144–147`). `/private/<name>` открывается через два `child(..., create:false)` с `O_NOFOLLOW`; весь дальнейший suffix идёт через `openat(O_DIRECTORY | O_NOFOLLOW)` (`:157–172,195–209`). Descendant с именем `var/tmp/etc` не становится OS alias. Whole-path symlink resolution не участвует в новой authority. |
| **URL rejection / prospective paths — CLOSED** | `ToolsFileSafety.pathComponents:63–70` требует local file URL, host nil/empty/`localhost`, absolute path без NUL и компонентов `.`/`..`; это выполняется до canonical spelling и walk. `checkedChild:45–49` сохраняет filename grammar и отдельно проверяет directory root/leaf. `ToolsDirectoryDescriptor.checkedPath:116–130` допускает только отсутствующий suffix; существующий symlink проверяется раньше ENOENT suffix. Проверка не создаёт каталогов. Returned URL не объявлен retained I/O capability: actual I/O снова получает descriptors. |
| **Retarget / target replacement — CLOSED** | `ToolsSystemAliasPin.verify:380–395` сравнивает сохранённую версию самого link, точный target text и followed target identity. `target.verify()` проверяет held `/private` и target bindings; новый inode по прежнему имени не принимается. `ToolsDirectoryDescriptor.verify:181–188` повторяет pin validation вместе с прежней цепочкой ancestor identities; child сохраняет тот же pin (`:206–208`). Snapshot не обновляется новым наблюдением после отказа. |
| **Snapshot lifetime — CLOSED в source** | Descriptor удерживает pin; pin удерживает root/target descriptors. Production pin-root создаётся с `systemAlias:nil`, и его target children также не ссылаются на создаваемый pin: retain cycle не образуется. Дочерние операции сохраняют authority до освобождения последнего владельца. Закрытие fd остаётся у прежнего `ToolsOwnedDescriptor.close/deinit` (`ToolsFileDescriptors.swift:66–83`), с обнулением владения до close. Runtime fd/leak measurement здесь не выполнялся. |
| **Actual consumers — CLOSED** | `ToolsBackupArchive.swift:151–165` делегирует filesystem validation общему `checkedPath`, сохраняя basename `settings` и allowlist. `EmojiPackStore.swift:16–18,138–151` хранит исходный root, создаёт его через no-follow opener и использует общий checked child; symlink не канонизируется в trusted root при init. `CloudSyncState.swift:30–32,35–63` использует тот же gate и opener с прежним `CloudError.localStorage`. Domain data formats/quotas/writers этим patch не переопределены. |

## TBF invariants и regression evidence

- Commit не меняет `ToolsBackupRestore.swift` и `ToolsFileOwnership.swift`;
  их raw hashes совпадают с предыдущим closure. Expected manifests, rollback/CAS,
  journal-v4 scratch receipts и cleanup debt сохраняются. Изменение descriptor
  verification добавляет OS-prefix pin перед прежней ancestor identity проверкой;
  leaf/version/hash и exclusive-publication bodies не заменены URL equality.
- `ToolsDarwinStorageTests.swift:15–39` использует **raw Foundation temporary URL**,
  читает реальные fixture bytes и выполняет настоящий client restore. Assertions
  требуют достижения `.afterPrepared`, наличия journal и его последующего retirement.
  Ранний `unsafePath` теперь не может выдать себя за проверенный fault boundary.
- Семь supplied cases также покрывают реальные OS-prefix **metadata** и home/temp
  spellings (`:42–60`), descendant symlinks с missing suffix (`:63–75`), retarget и
  replacement inode **в собственном miniature root** (`:77–104`), leaf race с
  двухсекундными synchronous barriers (`:106–133`), owned cleanup после rename
  (`:135–148`), actual Emoji/Cloud save/reopen и отказ redirected roots (`:150–174`).
  Реальные `/var`, `/tmp`, `/etc` fixtures не мутируют. Шесть cases доступны также
  Glibc; это не замена предстоящему Darwin execution.
- Remote-host/NUL/dot rejection подтверждён названными source guards; не выдан
  за отдельный выполненный test. Предыдущие negative-path passes также не выданы
  за positive-path доказательство нового cohort.

## SHA-256

Первые пять файлов — production scope; шестой путь относителен
`swift/ExteralessCore/Tests/ExteralessCoreTests/`. Последние два — сохранённые
production transaction/ownership bodies.

```text
0c9c2cbf7b42a57f78b8ae3146f77fede938207c4880eb396460b9bd31892ac5  ToolsFileSafety.swift
58be17374d0cf69ad690ccb3f8bb0ff0e467beabbbf260b2726a75dda464e119  ToolsFileDescriptors.swift
755fd1a52c261fcc12af3fef5a2667150fb549472775940eb239c718ec304351  ToolsBackupArchive.swift
d113dfbd492dbd9070209e433dfa5f93d81b064a203a162a9a4ad40c3367d041  EmojiPackStore.swift
54b14956daaea8272cb1ea33a79ec2daf2ed76f038adad6afc3467ceb6a3f510  CloudSyncState.swift
0797719ed671e9934a64a66b0cba2348305754d898f96d093b5fb302e5c83267  ToolsDarwinStorageTests.swift
5865c79e377cdc2464714e4879069ce5fd61fdc55e21aa59bf126fc705dc08d7  ToolsBackupRestore.swift
e4b546dc477be886905c0fccddc89fcfa9d205e181f1af85ed3a08944e0391c9  ToolsFileOwnership.swift
```

**Execution status:** post-fix Mac rerun pending coordinator. Source closure не
означает, что 34 failed filesystem methods уже прошли, и не подтверждает
Darwin power-loss durability, native Apple execution или UI frames.
