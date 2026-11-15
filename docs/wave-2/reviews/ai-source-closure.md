# AIAF-01 — source closure

2026-11-15. Точечная независимая проверка оставшегося P2 из `ai-af-followup.md`. Рабочий tree при HEAD `93a1badcb0ef414ca5218cf938e3b8e2be47a828`; вывод привязан к source bytes ниже.

**AIAF-01 — Closed/source. Остаточный P2 AF-03 устранён.** В проверенном исправлении новых P1/P2 не установлено. Native typecheck/link, Postbox/UIKit XCTest и recorded-frame acceptance остаются pending.

## Основание

Пути ниже относительны `telegram-ios/submodules/`.

- **Server revision:** `TelegramCore/Sources/ExteralessAI/ExteralessAIScope.swift:222–238` читает непосредственно `EditedMessageAttribute.date`, включая hidden edits. Смена 100 → 101 делает source equality false при неизменившемся partial preview; display-only `editedTime` не используется.
- **Actual merge → Seed:** `.EditMessage` в `TelegramCore/Sources/State/AccountStateManagementUtils.swift:4712–4725` и feed refresh в `TelegramCore/Sources/TelegramEngine/Feed/FeedPageStorage.swift:20–25` вызывают `ServerMessageMerge.swift:22–34`. Его invalidation branch удаляет derived translation/summary payloads, сохраняя incoming `fromLang` через `ExteralessAIMessageOperations.swift:94–104`. Затем настоящий `Postbox/Sources/MessageHistoryTable.swift:1613–1614` вызывает Seed closure. В `TelegramCore/Sources/SyncCore/SyncCore_StandaloneAccountTransaction.swift:175–186` восстановление прежней full page теперь требует **той же server revision**. При новом edit прежний `fullInstantPage` не возвращается.
- **Reload admission:** оставшийся incomplete preview достигает `TelegramUI/Sources/ExteralessClient/AI/ExteralessAIIntegration.swift:299–307`: `wholePage.isComplete == false` запускает scoped full-source load. Completion writer `ExteralessAIRichSource.swift:83–109` сохраняет новую полную страницу под version/lease guard и инвалидирует derived output.
- **Own-commit Retry:** translation commit сохраняет `EditedMessageAttribute` (`ExteralessAIMessageOperations.swift:122–149`), а scope получает фактическую Postbox `stableVersion` (`ExteralessAIScope.swift:68–83`). `ResultAccess.begin/resolve` (`ExteralessAIIntegration.swift:676–696`) переносит этот receipt. Server revision и local stableVersion не смешаны: собственный commit допускает Retry, новый server edit его отвергает.

## Проверенный regression fixture

`TelegramUI/Tests/AI/ExteralessAIFollowupNativeTests.swift:293–405`,
`testAIAF01SamePreviewServerEditReloadsFullSourceAndPreservesOwnCommitRetry`:

- visible/hidden edit labels; same-revision partial refresh сохраняет full cache и перевод;
- настоящий own translation commit → фактическая version advancement → успешный `ResultAccess` Retry;
- incoming revision 101 с тем же A → **после actual merge и Seed** нет OLD_B full cache/translation, свежая eligibility `es` сохранена; Retry прежнего scope отвергается;
- fresh scope → completion с A+NEW_C → реальный rich translator/AITranslationClient получает queries `{A, NEW_C}`, OLD_B отсутствует; последующий own-commit Retry сохраняет revision 101 и новую full page.

Fixture использует настоящий in-memory Postbox с `telegramPostboxSeedConfiguration` (`:439–458`), production merge/writer и ResultAccess. Счётчик full fetch расположен в тестовом условии `:369–378`; вызов actual network loader не исполняется этим fixture. Его production admission проверен по call graph выше. Содержательная regression coverage подтверждена чтением, **execution pass не заявлен**.

## Source fingerprints

Независимо вычисленные SHA-256 четырёх проверенных файлов:

| Путь относительно `telegram-ios/submodules/` | SHA-256 |
|---|---|
| `TelegramCore/Sources/ExteralessAI/ExteralessAIScope.swift` | `1700bcaac12be032a51abd6f433df993848994d5cc0853679ceb25cad727ec40` |
| `TelegramCore/Sources/State/ServerMessageMerge.swift` | `539233bee8e7460b3f501236390208a26a3d1fc5157bca3ec129d67a5e8f6a6e` |
| `TelegramCore/Sources/SyncCore/SyncCore_StandaloneAccountTransaction.swift` | `d4510003bf9fffadb776aae502104a602756248bd511876cc610f6e8f52c280a` |
| `TelegramUI/Tests/AI/ExteralessAIFollowupNativeTests.swift` | `b0b04693a66ca30c0b0b9079fef1e624974d01f727c248311ddaddfe582ebb4d` |

Четырёхфайловый manifest: `9df5d0efb888303b25e5c6d8953ea3ce1542791d0326f90a29a1e83f3af9371f`.
Алгоритм прежний: SHA-256 от sorted UTF-8 записей `repository-relative POSIX path + NUL + SHA256(raw bytes) + LF`, с полным префиксом `telegram-ios/submodules/`.

Сообщённый координатором Linux green `43712394860` / `93a1badc` не выполняет этот native Postbox fixture и не служит native acceptance. CI независимо не запрашивался; counts здесь не приписаны.

Reviewer выполнил source reads и bounded Python stdlib hashing (`-B`, timeout 20 s). XCTest, HTTP, accounts и recordings не запускались. Единственная запись — этот новый отчёт; четыре предыдущих AI reports сохранены.
