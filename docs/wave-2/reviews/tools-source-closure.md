# TBF-01–06 — source closure

**Все шесть прежних counterexamples: CLOSED на уровне source. Remaining P1/P2
в этом focused scope: нет.** Проверены исправленные алгоритмы, их production
callsites и соответствующие regression fixtures. Это не общий повторный аудит.

## Срез / evidence

- База refs `main` / `origin/main`:
  **`43c46497b961ee8a1ccdb9321bdcdae868747af4`**. TBF-01…04 — последующий
  working-tree срез, зафиксированный SHA-256 ниже; green **43716703817** его
  не покрывает.
- Helper и шесть Host tests TBF-05 совпадают с
  **`b5223dc0980dc5e66f7f4adb8ae905797b381d93`** (scoped diff пуст).
  Green **43714325169** / 6 tests — предоставленное coordinator свидетельство.
  Runtime и BUILD postimages прочитаны непосредственно, включая actual callsites.
- Учтены `tools-remediation.md:386–528`, `runtime-recovery-remediation.md` и
  прежний report. Source/BUILD стыковка уже применена, несмотря на исторические
  pending строки handoff. Новые 14 Core + 3 native fixtures прочитаны как source;
  23-case UI fixture остаётся Mac-pending.
- CI не читался/не запускался; Swift/native tests и live operations здесь не
  выполнялись. Darwin swap/power-loss, native decoder/UI execution и frames
  остаются отдельным acceptance. Старые reports не изменены.

Префиксы путей: `C/` = `swift/ExteralessCore/Sources/ExteralessCore/`,
`CT/` = `swift/ExteralessCore/Tests/ExteralessCoreTests/`,
`H/` = `swift/PluginHost/Sources/PluginHost/`,
`HT/` = `swift/PluginHost/Tests/PluginHostTests/`,
`UI/` = `telegram-ios/submodules/TelegramUI/`,
`TC/` = `telegram-ios/submodules/TelegramCore/Sources/`,
`NT/` = `telegram-ios/Tests/Exteraless/`.

## Закрытие точных случаев

| Finding | Source closure и проверка прежнего сценария |
|---|---|
| **TBF-01 — CLOSED** | `C/ToolsBackupRestore.swift:169–196,232–237,465–513,586–611`: target manifest выводится из проверенного original и admitted merge. Swap получает expected current/replacement manifests, проверяет их через retained `ToolsDirectoryImage` до/после exchange. Изменённый stage в `afterPrepared` не принимается за новый target. Backup image удерживается до client CAS и перепроверяется после `afterClientRollback`; копируется именно она, с проверкой original manifest. Ошибка сохраняет `needsRecovery`, без ложного commit/rollback и terminal cleanup. `CT/ToolsBackupFollowupTests.swift:98–137,197–208` воспроизводят обе прежние подмены, atomic/in-place, и сохраняют положительные commit/rollback controls. |
| **TBF-02 — CLOSED** | `TC/ExteralessTools/ToolsLocalFavoriteStickers.swift:24–42` вызывает новый throwing typed reader, а не `PreferencesEntry.get` / wire-selected generic decoder. `C/ToolsFavoritePostboxReader.swift:12–31,125–142,189–221,224–254` требует object-array для stickers, string-array для aliases/sr, bytes для fd. Прежние `[String]`, primitive-array и object-вместо-array входы бросают error до native construction. Canonical empty Int32Array(0) поддержан; v1 migration сохранена, cloud fd далее проходит `getCheckedRoot`. `CT/ToolsCachedFavoriteTests.swift:32–73` и `NT/ToolsFavoriteStorageNativeTests.swift:70–117` проверяют exact wrong-shape случаи; native fixtures используют реальные encoders и сохраняют исходные bytes. |
| **TBF-03 — CLOSED** | `C/ToolsBackupRestore.swift:207–209,531–547,630–699`: journal v4 содержит scratch ownership; client-only операция записывает пустой набор и не удаляет чужие UUID-shaped directories. `C/ToolsFileOwnership.swift:130–146,174–197` очищает recorded versions через held fd, удаляя только совпадающий пустой directory inode. Replacement directories и unknown/replaced entries сохраняются; cleanup debt архивируется до retirement active journal. v1/v2/v3 не получают ownership по имени (`ToolsBackupRestore:428–446`). Прежние оба scratch names, замена перед commit и terminal replay покрыты `CT/ToolsBackupFollowupTests.swift:39–94,141–193`. |
| **TBF-04 — CLOSED** | `C/ToolsReleaseClient.swift:63–82,323–360,378–441` передаёт caller retained `ToolsVerifiedFileReceipt` до закрытия write handle; final publication больше не использует URL-only move. `C/ToolsFileOwnership.swift:212–264` перепроверяет тот же fd/version/hash, делает no-replace publication и post-publication verification. Подмена A→B в `afterCleanup`, включая in-place, отвергается; foreign B и replacement folder не удаляются внешним recursive cleanup. `CT/ToolsReleaseTests.swift:181–260` воспроизводят точные handoff/error counterexamples, collision и cancellation; прежние positive download и late-callback controls сохранены. |
| **TBF-05 — CLOSED** | `UI/Sources/Exteraless/ExteralessPluginRuntime.swift:107–139,251–274,732–777`: оба startup tasks очищаются в defer; существующая continuation выбирается до new-Host guard. Keep-current service действительно вызывает этот binding (`UI/Sources/ExteralessClient/Tools/ExteralessBackupController.swift:104–120`). После успешного same-Host lease finish Runtime подтверждает captured receipt, снимает свой file gate и продолжает **тот же Host** в актуальном account scope. `H/PluginRuntimeStartupContinuation.swift:54–84,145–195` повторяет conservative recovery, перечитывает policy и допускает один ordinary start; failed reconciliation/retired scope его не разрешают. Шесть Host tests имеют сообщённый green; два actual-adapter/journal native fixtures находятся в `NT/RuntimeRecoveryContinuationTests.swift`. Target и deps реально добавлены в `NT/BUILD:196–224`. |
| **TBF-06 — CLOSED** | `UI/Sources/ExteralessClient/PluginUI/Tests/PluginUIRemediationFixture.swift:325–340`: fixed ISO timestamp, реальное encode/inspect и assertion сохранённого plugin payload выполняются до restore. Catch требует именно `invalidArchive("Plugin backup requires current native schema evidence.")`; fixture setup/другая ошибка больше не засчитываются за ожидаемый отказ. Прежняя premature termination до schema boundary устранена в source; весь 23-case запуск ещё Mac-pending. |

**Сохранённая Runtime стыковка:** `PluginConfigAuthority` передаётся в actual
manager writes, `.pinnedSet` остаётся одной операцией (`Runtime:628–653`).
HNS-F read по-прежнему захватывает read token до await и передаёт
`expectedOwner` / `shouldExecute` в `host.settingsJSON`, с post-result scope
check (`Runtime:404–431`). Cold recovery не создаёт второй Host и не использует
terminal stop→start. Это проверка сохранности названных callsites, не новый
вердикт по остальному SDK/Host.

## SHA-256 прочитанного среза

```text
5865c79e377cdc2464714e4879069ce5fd61fdc55e21aa59bf126fc705dc08d7  C/ToolsBackupRestore.swift
e4b546dc477be886905c0fccddc89fcfa9d205e181f1af85ed3a08944e0391c9  C/ToolsFileOwnership.swift
b39f7e44483c3842feca52b88ca8fd930e450e49b11f07181910083a3de55a1f  C/ToolsFileDescriptors.swift
f223e11ea77def7b314dba70060ae7219672aa9a28df60c678a24892fb28bf81  C/ToolsFavoritePostboxReader.swift
72b931f68a67d13da2cda2e560b2cce35fa699b19fda3f8f26be9ee2ff611843  C/ToolsReleaseClient.swift
63cfbc1b9ee03f88dc70cc6a866195a444aad3b28afed3c4be751c336d7fbb50  CT/ToolsBackupFollowupTests.swift
25e8a47f05dac27b84911f2d70635fa7bdb5d32410551927759922632ced5546  CT/ToolsCachedFavoriteTests.swift
f8fbc03d8f7ff780835e29eb16520254576f35862c140e96d08805b1114df4b3  CT/ToolsReleaseTests.swift
0e70f0c9d728eedff50d4e0d0553672842f0a7cc57699bd287aaa4f444a35c60  H/PluginRuntimeStartupContinuation.swift
1709bcc71e7bfef8f485c39692784e7dc664742a87d34c435ecc9cefc5471cbd  HT/PluginRuntimeStartupContinuationTests.swift
d8b866feea690aa12a06d4574d1cd7aec4f88a02b5253c3e402d261492236dc8  TC/ExteralessTools/ToolsLocalFavoriteStickers.swift
6998d97a25376dcdc8f9b965ef5fcc4f1a3309b309b30fd74e9c90ed13f019ee  UI/Sources/Exteraless/ExteralessPluginRuntime.swift
392c9f2cf76a090454403d9ee4466c019c2259ce5492810d70d80b5195553438  UI/Sources/ExteralessClient/Tools/ExteralessBackupController.swift
45e443a61da78034f692c8e6e3e52b9d5e58f1d42343f0c81ad73f4dabea3698  UI/Sources/ExteralessClient/PluginUI/Tests/PluginUIRemediationFixture.swift
af0ca7b5e9a0148b6ddee90ed3e1c9bca8ae5493123bd1dd0068fe36f0f390dc  NT/ToolsFavoriteStorageNativeTests.swift
6feff4016f564bb34122743a97f2bff36d359df68a6fc626e38caeb937eb7aff  NT/RuntimeRecoveryContinuationTests.swift
5c41fc8af5de1a08660a5765b5c49279cdc75ed3d7ae33c33eaaee5e32f6b335  NT/BUILD
```

Read-only originals:
`tools-backup.md` — `556bab814c3a01d20ebe42f20813620f8e72ff29abf31f53447ade3b3fe548ef`;
`tools-backup-followup.md` — `94bb8c897dd0b0b7b8934a78f255c75992a4307c41e4213b42678bd080cf877e`.
