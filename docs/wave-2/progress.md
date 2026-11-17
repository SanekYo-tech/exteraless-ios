# Полная волна — точка стыковки 16.11.2026

## Текущая точка

### Приоритет: чёрный экран build41 на устройстве

Пользователь сообщил: iOS27.0.1, IPA подписана без намеренного изменения Bundle ID.
**43912353956 /79fedf4f действительно SUCCESS**, но это packaging, не launch PASS.
Оба artifact ZIP скачаны с проверкой GitHub SHA-256. IPA41:98669864 байта,
`d3fe5fed758d6d374b44719fa8514473fee03dcd2784d0acb2165c3cd876e8ed`.
67arm64 Mach-O /6extensions /55runtimeframeworks /1413resources проверены;
436Gitpins +3 nestedRustpostimages совпадают. `ipa-build41-launch-investigation.md`.

Найден silent failure path: missing App Group → `Error 2` до windowScene →
bootstrap прекращён. Локально исправлена отложенная видимая диагностика при attach,
2 source-order tests PASS; причина на телефоне ещё не доказана.
Независимое startup review готово: `reviews/build41-launch-source-review.md`.
Дополнительные source paths — ClientAPI `.complete()` без account value,
блокировки Passcode/settings (внешний holder не наблюдался), write-probe pre-scene alert.
Локально исправлена scene-aware presentation write/API ошибок; 10checksPASS,
factory resumption/physicalrootcause не объявлены закрытыми.
API-message replay исправлен в7ba521c3 и независимо source-approved:
`reviews/build41-api-message-closure.md`. 11 tooling checks PASS; это не launch proof.
**Normal Telegram launch44110646483 выполняется:** immutable snapshot5b16fb66,
production base79fedf4f, локальныйf8e37b2dAppDelegatefix не включён.
Owner `ses_e1604ea3fffe290iCeY4oRJ2ZM` уже запустил watcher/download, не дублировать.
Ожидаются 2/10/20s screenshots, реальное видео/ffprobePTS и app logs;
native/visual результат пока не установлен.8 local smoke/launch-source checks PASS.
Старая формулировка «ENOSPC устранён накоплением outputs» не была подтверждена
замерами и не означает, что native434/visual20 прошли. Они остаются pending.
CI cleanup review принят: output reset удалён, EPERM не повышает cleanup до success,
recording reclamation требует terminal native/closedHTTP/realBazelshutdown.
Workflow wiring исправлен; normal-launch отдельно проверяет4GiB безудаления.
Coordinator53tests ran (51PASS/2POSIXskip); `ci-cleanup-correction-review.md`.
Device-build теперьнеотменяетsame-refUIKitjob. Изменения baseline44110646483некасаются.
`ses_e15e1d73fffeUuSeAdIagJQ37d` завершает оборванный unsigned archive clone patch
с малым Darwin proof. Их working-tree изменения до приёмки не публиковать.

Сборка **44121170313** / `f2baf586` собрала IPA 13.1.1 (42) и загрузила артефакт
`exteraless-ios-13.1.1-42`. Job сборки SUCCESS. Публикация релиза упала: upload-artifact
сохранил абсолютный путь `Shared/telegram-ios/build/artifacts/*`, а publish искал
файлы в корне. Повторная сборка не нужна. Короткий publish-existing workflow публикует
этот же артефакт после проверки SHA-256. Это не launch PASS и не приёмка 434/20.

### Актуально: общий source cohort опубликован, Apple-приёмка выполняется

**HEAD `79fedf4f`; полный Mac gate на `d8705c51` GREEN**:43795739683, workflow build33.
**Независимая проверка runtime33 PASS:** `runtime-native-acceptance-33.md`.
[IPA Build 43912353956](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43912353956) выполняется.
UIKit gate был отменён общим concurrency-key iOS Build (`cancel-in-progress: true`);
будет перезапущен после завершения IPA. Compat `735be8e5` GREEN.
722Core/273Host/30Hooks,23HNS,47FD/7ingress/4Mode и пять реальных SDK children:
4.227/2.672/0.997/7.159/5.566s. C219/169/41, cleanup2/2,629/629Gitfingerprints.
Archive/developer fixtures получили штатный vendor root;
78e76dbe публикует проверенный Darwin identity-selector для archive fixture;
53cab85a исправляет resource ID в debug Feed fixture.
Общий Host/SDK/UIKit cohort — `f704d76c` (288 файлов); hermetic parity overlay
опубликован в `3daf8d97`:39 source-closed scopes,34 raw report snapshots,
исторические567/925 и14/102/666 сохранены, verification promotions=0.
Runtime33 evidence добавлен новым hermetic overlay:35-й snapshot,
NativeSDK5 — completed в точном runtime-component scope.16/16 deliveryhashes
сверены; regeneration/check-data безGit и Config--checkPASS.
`docs/parity/current-runtime33-handoff.md`; прежние34snapshots/pins сохранены.

| Актуальная проверка | Подтверждённое состояние |
|---|---|
| Compat | **43852477202 /d245ec52 GREEN:521 PASS /36skip**,185.35s; Swift job skipped by path filter |
| Linux Swift | **712 Core /273 Host /30 Hooks PASS**, последний полный d296e456 |
| Mac component scopes | **722 Core /30 Hooks**,297 Git pins; listener,47FD,7ingress,4ModeABA также отдельно PASS |
| Последний полный Mac | **43795739683 /d8705c51 GREEN + independent PASS**,722Core/273Host/30Hooks,5SDKchildren,C219 |
| UIKit | **43852504839 /d245ec52 FAILED**: 33/37 native targets собраны, четыре остановлены ENOSPC; места для frame tools тоже не хватило |
| План приёмки | **5 real SDK children PASS**;434 native XCTest methods и20 записываемых сцен ещё pending |
| Проверенная unsigned IPA | **build40 /43779402542 /6de4ac36**,98 177 711байт; новый source cohort не входит |

**Активные независимые работы — не poll:**
- UIKit43852504839 завершён; watcher завершён. 5927 action /1943 remote cache hits,
  compile715.911s:33/37targets. Free21.48GB→139MB; 4 поздних ENOSPC, source diagnostics=0.
  Cache completeness работает. 102 Mac tooling checks PASS (17.862s), включая
  настоящий POSIX whole-group SIGTERM и отрицательный child exit; 29 harness checks PASS.
- `ses_e1bc65877ffewSDpIp7RfHUHm7`: уменьшение unsigned test-archive дублирования,
  с малым настоящим APFS copy-on-write proof перед полным Apple-повтором.
- `ses_e25088d28ffem4nSC3FcOP577B`: отдельная bounded capacity recovery перед
  frame tools/recordings; оставшийся claimed cache5.95GB доступен для этого этапа.

**Корневая причина ENOSPC — накопление output bases.** Rsync-staging не чистит
sibling `bazel-user-root`; выходы3+ прогонов занимали60–80GB. Координатор добавил
`native_test_disk.py reset` (после staging, удаляет только execroot-каталоги,
сохраняет install/lock) и `recordings` (после native, реклеймит cache до4GiB
floor для pip/ffmpeg/кадров).53 local testsPASS,1744inputscovered.
- Compat43852477202/d245ec52 завершён GREEN: 521 PASS /36 skips; watcher завершён.
- Общий corrective cohort опубликован: 24 файла; 9 recording envelopes согласованы
  с owned-exec, 77 local PASS/4 POSIX skip,1743 inputs. Все delegated owners завершены.
- UIKit43834798503 завершён; watcher завершён. Cache: 40818 hits /562 misses,
  2.22GB прочитано; native result FAILED, классы/кадры не исполнялись.
- Cache completeness после reclamation готова и проверена на реальном Bazel.
  Реальный Linux Bazel воспроизвёл orphan `AC200 + CAS404 → Lost inputs`.
  AC-completeness→404, eager downloads и NEO-01 применены; 50 local /25 Linux
  tooling checks PASS. Два прежних run failed на probe assertions сохранены;
  третий короткий Linux run завершил end-to-end проверку.
  **43846695323 /219080d9 PASS**: 8 сценариев /25 Linux tests; baseline failure
  воспроизведён, fixed AC404 пересчитывает producer/consumer, после GC повторяется
  только consumer. Координатор сверил 5 delivery hashes, Git source bytes,
  16 artifact hashes, события всех восьми cases и семь закрытых server lifetimes.
- Glass fixture готов: три `@MainActor`-аннотации, 4 ID /25 assertions сохранены;
  `native-glass-actor-followup.md`, postimage `cf6a1e64…`.
- Orchestration review готов: `native-execution-orchestration-review.md`.
  NEO-01 (run-only test_env) передан cache/driver owner; NEO-02 (Composer process
  bootstrap) готов: 6/6 raw postimages сверены, 8 source checks PASS,
  37 targets /92 classes /434 methods сохранены. `native-composer-bootstrap-followup.md`.
- NEO-03: diagnostic recording fallback реализован координатором; 27 tooling
  checks PASS. Следующий dispatch использует `diagnostic_recordings=true` для
  ранней диагностики кадров. Финальная приёмка требует полного native PASS.
  Независимое ревью не нашло admission bypass; три P2 аварийных paths (SIGTERM,
  driver-path loss, CLI exit preservation) исправлены. Девять envelope arguments
  добавлены в workflow; 81 coordinator tests (77PASS/4POSIXskip),1743inputscovered,
  Config276/0/32 неизменён. `native-cache-orchestration-integration.md`.
- Compat43834762569/b06bb000 завершён GREEN; watcher завершён.
- UIKit43827361709 завершён. Recovery25.038s:10.01GB/7120deletes, free22.39GB,
  kept8.59GB. ENOSPCнет; compile785s завершилсяна2926/8887actions (Abseil rebuild).
  disk_cache= изменилcache-enabledaction-salt. Ownerпроверяетreadonlyenabled-cache
  вариант, чтобысохранитьreuse безновыхдублирующихcachewrites; floors/37/434/20сохранены.
  Readonlycacheготов:8/8postimages,43checks(2POSIXskip),1739inputscovered.
  HTTPloopbackAC/CAS GET/HEAD сохраняет cache-enabledsalt; writesdisabled,
  marker/FD/capacity/cleanupchecks сохранены. `native-test-readonly-cache-followup.md`.
- Compat43827337107/f1c28499 завершён GREEN; watcher завершён.
- UIKit43822623419 завершён; watcher завершён. Free2.75→9.31GB, удалено6.41GB/
  37728cachefiles; осталось18.54GBeligiblecache. Floor20GiB не достигнут, compile не стартовал.
  ses_e25088d28ffem4nSC3FcOP577B добавляет pressure-aware large-blob priority втотже60sbudget;
  ownership/FD/free-space checks и37/434/20 не ослабляются.
  Pressure policy готов и принят:3/3postimages,17tests(1POSIXskip), regression2000tiny
  entries достигаетfloor за3big-blob deletes. `native-test-disk-pressure-followup.md`.
- Compat43822586271/bfcce7bc завершён GREEN; watcher завершён.
- UIKit43812503558 завершён; watcher завершён. Core fixtures —ses_e1d06c8f8ffehjPM0uMig1HERu;
  graphics —ses_e1d06c8a7ffekqpt3ouAeKRg28; AI —ses_e1d06c8a5ffeudGDP7qGkCTe8V;
  Feed/Presence/Chats —ses_e1d06c8a3ffezy3nUjXSB6kizy;
  native test graph/link/resources —ses_e25088d28ffem4nSC3FcOP577B.
  Graphics ready:5testfiles/11substitutions,21XCTestIDsunchanged;
  `native-graphics-fixture-typecheck.md`. Остальные группы ещё в работе.
  AI ready:2testfiles,14IDs/137 прежних assertions сохранены; native Signals и
  InstantPage остаются на MainActor, черезTask выходитVoid/error.
  `native-ai-fixture-typecheck.md`.
  Core ready:5files/41IDs/281assertions; Feed/Presence/Chats ready:5files/23IDs/147assertions.
  `native-core-fixture-typecheck.md`, `native-feed-presence-fixture-typecheck.md`.
  Все17fixturefiles готовы; ожидается test-bundle graph/link/resource delta.
  Coordinator сверил17/17postimages; nativePlan37targets/434methods сохранён.
  Graphowner установилENOSPCдляChatSwipe+четырёхlinkactions; неsymbol/collision.
  ItemListUIdependency+2imports применены. Ownerготовитboundedcache/free-space
  recovery передnativecompile; исходники/IPA/Bazeloutput не удаляются.
  Recoveryready:6/6postimages/ZIPverified,23toolingchecks(1POSIXskip),1737inputs
  иConfig--checkPASS. Nativephase20GiBfloor/30GiBgoal/60sreclaim; diskcachewritesoff.
  Полныйcohort готовкcommit: `native-test-correction-cohort.md`.
  Coordinator regenerated SharedAccountContext: единственный makeShareScreen stub,
 243generatedmethods, exactgeneratoroutputverified.434testmethods/20scenes retained.
- Compat43812484349/93dcb653 завершён GREEN; watcher завершён.
- UIKit43809909587 завершёнfailure, watcher завершён. Native step осталсябез
  conclusion; annotations пусты, artifacts отсутствуют. Причина не установлена.
  `run_logged` теперь зеркалирует boundedcompiler/XCTestoutput вActions;9checksPASS.
- Compat43809888695/ee40679a завершён GREEN; watcher завершён.
- UIKit43807905674 завершён: packaging строгихPNG/Python/FD resources PASS.
  Native compile дошёл доPluginManagerAuthorityTests; ожидание вынесено в ordinary
  DispatchQueue с checked continuation,2sdeadline/assertions сохранены.
  Native compile теперьkeep_going;9planner/fixture-class checksPASS.
- UIKit43805552582 завершён: оба app targets собраны/слинкованы; verifier обнаружил
  изменённые CopyPng байты. Map PNG передан через structured_resources; исходный
  hash и точная bundle byte equality сохранены.29harness+4Maptooling checksPASS.
- UIKit43801470131 завершён. Composer импортирует Postbox RenderedPeer;
  Feed использует isComplete и явные Engine-типы.29harness tests/import checkPASS.
- writeSettings link cause подтверждён Xcode27.1 probe43804717243:
  inferred preconcurrency стирал @Sendable в base symbol, но не в inherited vtable.
  Explicit @MainActor даёт matching symbols/link0; тело и guards byte-identical.
  `uikit-chat-table-link-remediation.md`; полная сборка ещё требуется.
- UIKit43797987677 завершён; watcher завершён. CustomCell использует inherited
  gesture delegate/override; reset caller передаёт underlying AnyObject с nil-preserving
  Optional.map. `uikit-manager-reset-typecheck.md`; Postbox import checkPASS.
- Mac43795739683/d8705c51 завершён GREEN; watcher завершён.
- Compat43795725685/d8705c51 завершён GREEN; watcher завершён.
- Compat43795070738/78e76dbe завершён GREEN; его watcher завершён.
- UIKit43793245829 завершён; watcher завершён. Исправляется единственная
  диагностированная в этом проходе Map weak-variable warning-as-error.
- Runtime33 проверен:43MB runtime,430KB components и49SDKentries через7.05MB Range
  requests. Полный SDK ZIP hash не пересчитывался;13pytestskips, непереданные
  staged/vendor bytes иliveFScleanup остаются явно ограниченными scopes.
  ProbeIPA56unsignedarm64Mach-O; это не новая полная TelegramIPA и неUIKitframes.
- Archive swap fixture завершён: **Darwin43794021047/cef03eec 7/7PASS**.
  Наблюдения подтвердили один inode при разных /var и /private/var labels;
  fixture выбирает захваченную identity и проверяет точный отказ storage.
  Testpostimage b9b101e1 и artifact conclusion сверены с Git/receipt.
- Независимый SDK run43794176737/3daf завершён: actual baseline/TL/HNS PASS;
  archive failed на отсутствующем vendor root в fixture bootstrap, fifth не запущен.
  Все374 source pins сверены; production standard() уже содержит vendor.
  Две fixture configurations исправлены,13tooling+1fixture checksPASS.
  Следующий общий Mac gate включает эти исправления и проверенный swap fixture.

### История промежуточных gates до 53cab85a

Состояния «выполняется» ниже относятся к указанным checkpoint; актуальные owners
и watchers перечислены выше.

Mac43786995069/5fa35f34 завершён FAILED, watcher завершён.
Отдельно **722 Core /30 Hooks PASS**, все297 source pins сверены с Git:
`mac-core-722-acceptance.md`. Host заблокирован конфликтом `kevent`, standalone UI —
closure inference. Оба source fixes готовы (`darwin-sdk-typecheck.md`).
Listener readiness исправлен и проверен: Darwin43787862250/bbc54817 PASS,
compile9.864s/execute0.337s. Шесть inputs и три изменённых postimages сверены с
passing artifact/Git. Причина — EINVAL от двойного задания endpoint/port;
NWListener(using:) сохраняет127.0.0.1:42690. HNS/Mac5 ещё не выполнены.

Предыдущие watchers завершены. Compat43786135131/a823e619 GREEN:
478 passed,36 skipped,147.86s. Mac43786148988 прошёл91 packaging,63 plumbing
и49 finite SDK tests (13 пропусков), затем failed на readiness реального listener.
Отдельный bounded Darwin-прогон установил и закрыл этот listener-дефект;
`developer-listener-native-remediation.md` содержит точное состояние и evidence.

Mac43785374048 и Compat43785348360 остановились на импорте pytest из helper
в изолированном child. Исправление опубликовано в a823e619; локально4PASS,
10 явных Windows/C-пропусков и изолированный emitterPASS.
UIKit43785534046 завершился до компиляции на `aquery`: Postbox не разрешал
ExteralessHarness в test_clients. Точное исключение и bounded diagnostics готовы;
5/5 postimages сверены,29harness testsPASS. Следующий build использует --keep_going.
README/PLAN/runtime docs и Obsidian обновлены; source closure overlays в parity
сводит `ses_e1fc2b7aeffe9GcuqtB99tTZZz`.
Overlay готов:39 закрытых scopes,56/56 output hashes сверены;34 raw report snapshots
делают его независимым от Git history. 43 focused testsPASS; coordinator повторил
--individual-only --docs-only --check и --check-data с запрещёнными subprocess —PASS.
SDK --check подтверждает276/0/32 и прежний canonical contract. Исторические maps,
64f704fix-pins и zero verification promotions сохранены. Публикация ниже.

**Текущие watchers — не poll:**
- Mac43791248294/5ce84b96: `sh_1e2253b630012ZKTZdDpGxeC6L`, `python-5ce84b96-watch.log`.
Compat43791231210/5ce84b96 завершён GREEN; watcher завершён.
- UIKit43788169856: `sh_1e2088cca001U378Kki29sg3D6`, `uikit-d296e456-watch.log`.
Mac43789795179/1df7fda0 завершён: listener/47FD/7ingress/4ModeABA PASS.
Полный Host скомпилирован и выполнен; один archive test не включил swap-hook из-за
сравнения /var с /private/var. Ожидаемый путь fixture нормализован до установки hook;
expected throw и обе проверки сохранности деревьев сохранены. Новый run требуется.
Compat43789426184/433435e8 завершён GREEN.
Compat43789773288/1df7fda0 также GREEN; его watcher завершён.
Mac43788170016/d296e456 завершён: candidate/7ingress/4ModeABA/UI-model/TL/Java/
Core/Hooks PASS. Host test compiler остановился на четырёх `Self.native` внутри
Task; строки вынесены до capture, все barriers/assertions сохранены. Listener
в этом старом run ещё падал; его исправление78f37532 уже отдельно DarwinPASS.
Mac43789436374/433435e8 остановился раньше: tooling mock не принимал новый
listener `log=`. Mock исправлен с проверкой обоих путей; локально все91 packaging
tests PASS. Это не native-regression и не новая runtime-ошибка.
Compat43788453589/78f37532 завершён GREEN; его watcher завершён.
Compat43788114300/d296e456 завершён GREEN:712Core/273Host/30Hooks
(9.111/5.571/0.657s),478PythonPASS/36skip (172.88s).
Darwin compiler fixes и Postbox visibility опубликованы; старый UI postimage
сохранён, новый admission manifest — `plugin-ui-darwin-compiler-postimage.json`.
Listener fix78f37532 новее этих трёх runs. Текущий Mac собирает остальные
независимые результаты; его ещё не отменяем новым dispatch.

| Проверка / поставка | Текущее подтверждённое состояние |
|---|---|
| HEAD | **5ce84b96**: Darwin parent-swap fixture hook path correction |
| Полный Mac/CPython gate | **43743252038 / e16f3808 GREEN, independent PASS**:680 Core /180 Host /30 Hooks,9 Ghost tests,3 native SDK child,iOS219 |
| Linux Swift | **43788114300 /d296e456 GREEN:712 Core /273 Host /30 Hooks**,9.111/5.571/0.657s |
| Linux Python | **43788114300 /d296e456 GREEN:478 PASS /36skip**,172.88s |
| FD / mode native | **47 FD PASS** в43784959730; **7 ingress PASS** в43781210777; **4 Mode ABA PASS** в43783735908 |
| SDK Config | **276 implemented / 0 blocked / 32 unsupported**, ровно 308 API; 59 source pins / 10 input receipts |
| Native XCTest / UIKit | Finaltooling: **37labels /89sources /92classes /434methods**,20scenes и5realSDKchildren; delivery10/10verified, execution/framespending |
| Полная IPA | **43779402542 /6de4ac36 GREEN, build40**, independentlyPASS; artifact14187634135 |
| Последняя проверенная Telegram IPA | **build40 /43779402542 /6de4ac36**, 98 177 711байт |

**IPA watcher завершён SUCCESS.** `43779402542/6de4ac36`,build40:
`exteraless-ios-13.1.1-40`/14187634135,ZIP273790711bytes/SHA
03c89e65e136ab7ae8388b377097b0cdb296ca936d6a68ec0ed3d1665be969d6.
Preflight14188291130. Независимый отчёт — `ipa-build40-acceptance.md`;
артефакты сохранены в `build/artifacts/telegram-43779402542`.
Проверка завершенаPASS:67unsignedarm64Mach-O/60frameworks/6extensions,
1418placements/419sourcepins. IPA-SHAe28940fdb017941525824ba1906d09e32da6bd973fa1c1c7c41bd294eeee3d99.
Короткийdeliverypath:build/artifacts/telegram-43779402542/exteraless-ios-13.1.1-40-unsigned.ipa.
НовыйHost/SDKcohort/UI20ещёнепокрываютсяэтойIPA. Rustpatch/gilbaseверны;неpoll.

## История интеграции и прежних checkpoint

Ниже сохранены последовательные записи. Текущее состояние и активные owners
указаны в верхней секции; старые слова «в работе» относятся к своим checkpoint.

**FullCompat43784503847/f704d76c завершён:** SwiftjobSUCCESS712Core/273Host/30Hooks
(9.176/5.545/0.356s), включаявсеFD47. Python428PASS/37skip/49fail из-заединственной
причины:stagedPyYAMLненапутиимпорта. КоордобавилPYTHONPATH=python/vendorвpyteststep.
Watcherзавершён. Mac5/UIKit20следуютпокогерентномусрезу;SDK276/0/32checkPASS.
43769738884 завершиласьнадвухMessageMediaActionsdiagnostics; cacheработал:
7216disk-cachehits из9654processes,675workeractions. Следующийbuildиспользуеттотжеcache.
Linux/POSIX Host follow-up ведётотдельно `ses_e1ec1979effeHeE6OKLhF3XvXz` на
изолированнойci-ветке; основнойHEAD/indexоннеменяет. Неpoll.
Первый watcher f05473ea завершился поTLS handshake timeout; GitHub подтвердил
`in_progress`, сам build не перезапускался. 43758245026 завершилась на unused rawHeight вPeerInfo;
исправленоf05473ea. Core/Compat43759513734 GREEN; егоwatcherзавершён. Не poll.
ПервыйIPAwatcher590ce05bоборвалсяпоTLS timeout; GitHubподтвердилin_progress,
jobнеперезапускался. ResetCI43758843590compiled/ran,единственныйfailedmethodне
регистрировалDialogFeatures(145вместо148keys);1880b663добавляетреальнуюгруппу,
сохраняя148иexactunavailableassertions. Productionresolverнеизменён.

SearchCI43763528246 compiled/ran; одинfixture ошибочно читалJSONпослеодной
регистрациисхемы. 4bd2f7e3создаётреальныйoverrideчерезsetPublicдоfilebaseline,
сохраняявсеschemaABA/неизменностьбайтовassertions; productiondeltaотсутствует.
Bubble590ce05b сохраняет native comment-condition и timestamp того жеforwardInfo;
Core/Compat43757030337 GREEN остаётся687/180/30 baselineдоreset17.
43756548501 compiledCore иупаланатолькоодномtest:fixtureлокализовалаоднимзаголовком
иSearch.Title,иsetting.Title. 93edf05eсохраняетassertionнаlocalizedsetting, исправляет
mapperнаexactkeyидобавляетконтрольобычногоSearch. Новогоindexbugэтотfailureнепоказал.
43754686421 завершилась на optional primaryContext floating-compose guard;
исправлено47858c64. Предыдущие watchers завершены.
Последние full-app compiler corrections: e16 —25 TelegramCore diagnostics,
5a4 —generic prepared Network,9956 —Camera factors/SSK/Rust notification,
e766 —cached nil initial zoom state в Legacy/Neo.
43749522967/e766 дошла до ChatTextInputPanelNode и завершилась на двух diagnostics;
00bf3344 использует предыдущий property snapshot и современные button insets/font.

Runtime run20 скачан в `build/artifacts/python-runtime-43743252038/{runtime,swift-components}`.
Независимый receipt: `runtime-native-acceptance-20.md` и `local-verification.json`.
Проверены565/565 Git fingerprints,314 build inputs,9/9 Ghost tests,C219/169/41,
2/2 terminal payload cleanup и56 unsigned arm64 Mach-O. IPA-SHA
`2ce31c2ca798b0857cbad194b5c3d07a51a1d7b678647f29b36ec395e9fab1f5` — диагностическая
runtime IPA, не полная Telegram IPA.

Полный runtime run19 скачан в `build/artifacts/python-runtime-43738810843/`:
`runtime/`, `device/`, `swift-components/`. **Независимый PASS** записан в
`runtime-native-acceptance.md` и `local-verification.json`:671/180/30 tests,
23 HNS, три SDK child (6.734/4.570/1.611s), iOS219/169/41 и payload cleanup2/2.
1002 уникальных Git blobs +2 gitlink blobs +2 generated inputs сверены; probe IPA
56 unsigned arm64 Mach-O, SHA4e7e0d82e72bef3b0c6823225405c06f874f8e33524894e10f3238c1cb1ec4ee.

IPA43738711102/136c946f выявила оставшиеся unannotated properties/blocks MtProtoKit
и iOS-unavailable `CTFontTableOptions.excludeSynthetic`. fac6cf26 завершает все
pointer annotations и читает cmap непосредственно через `CGFont.table(for:)`.
Разбор compile-цепочки — `ios-compile-remediation.md`.

TelegramCore compiler cohort опубликован e16 и прошёл последующую компиляцию.
Nonnull нового MTRequest initializer и typed redacted Mirror включены.

Frozen UIKit delivery принят **22/22 по точным Git bytes**, prerequisites110 без
drift. Исходный source boundary e2a5684c сохранён в receipts; опубликованные позже
ClientSettings/iOS compiler fixes также входят в текущую ветку. Native test и
recording workflow запускается после прохода full-app compiler gate.

Все последние source-review finding groups закрыты: PNP01–03, PFM01, ASC01,
CMC03/05, Feed/Player FU01–04, TLN-F01/F02, Darwin storage. Native XCTest и кадры
с их actual frame/PTS references остаются обязательными acceptance gates.

Атомарный Ghost Mode опубликован в1afee5f9, independently source-closed и9/9MacPASS.
SCR01 quarantine source follow-up также завершён: `reviews/settings-quarantine-source-closure.md`,
три named Mac tests PASS. Новая UI wording-delta различает unknown secret и confirmed
absence; её actual UILabel probe добавлен воба core-сценария(теперь11probes),3+3+2сохранены.

567-source join опубликован9bfce05f,0receiptgaps. Индивидуальные925 SDK routes готовы:
249core-api+267utilities+262Elyx+147UI, и14/102/666 General/Settings/Plugins method maps.
Они включают metadata, partial и unsupported; это не925работающихAPI. Новый exact-ID
join опубликован в `8b726b75`: обычная регенерация сохраняет все925маршрутов,
14/102/666module identities и исходные boundaries; verification promotions=0.

### Активные исправления конкретных SDK/route findings

**Состояние последних review findings:**
- NFD-01/03 independentlysource-closed иstartup/TLSjoined; последнийP2
  **DEV-LIFECYCLE-01**: конкурентныеoff/onскрываютoffотactorcontinuations.
  **DEV-LIFECYCLE01 исправлен иsource-closed**, actual4-testLinuxgateGREEN.
  `reviews/native-elyx-mode-aba-closure.md`, `elyx-mode-aba-posix-ci.md`.
- **Новый FD-provider review: NFD-01 P1 +NFD-02/03 P2**, см.
  `reviews/native-elyx-fd-authority-review.md`. **NFD-01/03 fixes готовы иsealed**:
  native-elyx-developer-final-inputs.json,41postimages/58pinscoorPASS.
  Actualstartup/TLS/epoch/readiness/teardownAPPLIED;повторныйFDreviewвработе.
  **NFD-02fixготов**:
  FDinspectionприменяетsharedload-policyдоreturn;ordinarypreviewсохранён.
  Sealedinputs`elyx-nfd02-inputs.json`;12PythonPASS/3POSIXskip.
  **Независимоеsource-closureNFD-02получено:** `reviews/elyx-nfd02-closure.md`.
  **Linux43774694321/ff0c9fbd GREEN:50/50,0skip,19.238s,167pins**, включаяNFD02
  иplatformsuite. `elyx-load-preflight-posix-ci.md`;NFD01/03повторныйreviewpending.
  Startup/5-йchildпродолжаются.
- Независимо source-closed: Search R1–R5, Reset RSR01–02, Custom MCA-F01/F02
  Trust S1–S3 и восемь ранее проверенных SDK контрпримеров. Native/render acceptance pending.
- Reset RSR01–02:2P2 (`reviews/settings-reset-source-closure.md`) — cancelled-pop
  preview recovery и post-commit same-payload restoration перед retry. Fixesготовы;
  Coreaca0eb38вCI(19resetmethods), UIViewDidAppear recoveryвworkingtree.
  **Независимоеsource-closureполучено:** `reviews/settings-reset-rsr-closure.md`.
  Все19Coreметодов исполнены в43764252538/aca0eb38 GREEN.
  Nativegateowner подключает10fresh Display cases какотдельныйrecording supplement,
  сохраняяbaseline8/3+3+2 и30sнакаждыйпроцесс.
- Trust secondary permissions:3P2 S1–S3 (`reviews/plugin-trust-level-source-closure.md`)
  — TL external media.files, deferred UI link.intents и late-grant Share.files.
  Consumer fixesготовы; RuntimeclassifyShareFile+BUILD3hunksAPPLIED. Полный набор
  зависимостей capturedприadmission, carriedчерезprep/open/callback.
  **Независимоеsource-closureполучено:** `reviews/plugin-trust-secondary-closure.md`,
  8readyhashes/36inputpins и actual Runtime wiring подтверждены.
- SettingsSearch MS-ROUTE-01:5P2sourcewitnessesR1–R5(`settings-search-source-closure.md`)
  — launchconsumer-before-intents,pendingURLsessionABA,schemaeventABA,defaultRoot
  nilauthorityfallback,explicitclassqualification. Production fixesAPPLIED19paths;
  Core16+6fixturesGREEN4bd2f7e3. **Независимоеsource-closureR1–R5получено**:
  `reviews/settings-search-r1-r5-closure.md`; в этихпятиcounterexamplesнетP1/P2.
- Archive GAP01:3P1 (`reviews/elyx-archive-source-closure.md`) — cached.pyc filenames,
  immutable/code-protected execution, fd/nofollow extraction/cleanup —
  **ARCH01/02/03 source-closed** в `reviews/elyx-archive-p1-closure.md`.
  P2 sys.platform=ios исправленвтрёхselectors;4portabletestsPASS/1POSIXskip.
  РеальныйDarwin/iOS SDK FD-probe APPLIEDвnative_plugin_probe/native_wave_probe;
  **Независимоеsource-closureполучено:** `reviews/elyx-ios-platform-closure.md`.
  Actual iOS FD flag ещёожидаетсвежегоAppleпрогона.
  Cgate+Swiftregistryhook+Hostcapture-before-unloadhunksAPPLIED.
- ManagerCustom/alias:2P2 (`reviews/manager-custom-alias-source-closure.md`) —
  callbacksnapshot refreshдоnativecommit иrootclickобгоняетinlineFIFO. Fixesполучены:
  commitACK +единыйinline/rootFIFO;17sharedpostimagesAPPLIED,10ownedpinsсовпали.
  15PythoncasesPASS,7newnativecasespending. **Независимоеsource-closureполучено:**
  `reviews/manager-custom-ordering-closure.md`,5focusedPythoncasesPASS.
- NativeElyxdevelopercommand ingress: P2;8остальныхSDKcounterexamplesclosedsource.
  FDprovider/registryv1 реализованы(21nativeFSfixtures). Developerowner завершает
  реальныйstartup/readiness/TLS/teardown join и5-йbounded realSwift/C/SDKchild;
  контракт `elyx-source-descriptor-v1.json`, opaque11-keycapability,безrawFDwire.

**Выполненные дополнительные gates:**
- Linux43768124344/ff913492:42PythonPASS/0skip,все17бывшихPOSIXskipsвыполнены,
  freshCbuild. Swiftcompilefailedнаclosureinference;отчёт`elyx-posix-ci.md`.
- Swift-only43769449668/ec1131cf прошёлпервуюпроблемуиостановилсянааналогичном
  `BridgeServices.nativeEffectLease`;обаfuturePredicateexpressions исправлены,
  **43771162142/0ad00c3e GREEN:53HostPASS/0skip**,7actualdescriptorcases,
  build17.88s/run0.569s,166pinsverified. `elyx-posix-host-final.md`.
  Capture21-caseFDprovider/registryсрезаостановлен:2активноизменённыхфайла
  отличаютсяотстарыхhandoffpins. Ветка/CIнесоздавались;
  `elyx-fd-provider-posix-ci.md`. Новыesealedpins придутсготовымstartup/5th-childhandoff.
- Fresh instrumentedCgate:7/7наPy3.12и3.14,61nativecalls/60buffersfreed/
  33contextsreleasedнаверсию,дваOWN_GILowners. `elyx-c-gate-validation.md`.
  ЭтоCtransportproof; productionFDregistry/Appleещётребуютисполнения.

**Последний compiler cohort:**33Swiftpaths,27authorposthashes,2scopedindexhunks
дляRoot/MainMenu и59SDKrawpins/10receiptsпроверены. Counts276/0/32,508bindings.
`ios-telegram-ui-compiler-cohort.md`ссылаетсянавсе5groupreceipts.
SourceSearch/Reset иновыйHost/SDKWIPсохраненыдляследующегосогласованногосреза.

NativeFDv1provider/startup/TLS теперьAPPLIED:47Host+7Ingressnativecasesподготовлены,
новыйPOSIXCIнаsealedinputsведёт `ses_e1ec1979effeHeE6OKLhF3XvXz`.
43779077310/ecaa9d85проверил184pins, compilefailedнаCoreFoundation/GlibcS_IFREG
ambiguity. КоординаторявноуказалDarwin/Glibcconsts;повторяетсятотже47+7gate.
43780298237/a5720a43прошёлэтотsite, затемнашёлtest391throwing`||`безобщегоtry.
Однострочныйfixturefixприменён;deadlineиassertionsсохранены,47+7CIповторяется.
CoordinatorAPPLIED12toolinghunksпятогоrealSwift/C/FD/SDKchild;11,416bytesownedinputs,
30sprocess; тотжеpublicHost activation APIпроверяетreadiness/compare/changes/reload.
Finalsource-review — `ses_e1f405489ffeax73Cv9nGJs0Se`; native execution pending.
Toolingowner сводитfinalfive-child/sparseinputs иupdatednative-testmap.
Finaltoolingполучен:1731inputs,10deliverypathsбезdrift,ZIP
70a05606b7f2011810e0ece439cd512e549f89cb902d0569d77c153f534aaa66.
16tooling+5fixture/readinesschecksPASS;передMacпубликациейнужнаRootpinregeneration.
Map20-йscene: actualMKMapViewвфиксированномтестовомрегионе, локальныеOSMtile
inputs/failure; стандартныеpublicMapKit/GeoServicesзапросыдопущены, egress-disabled
неутверждается. Entry/framevalidationготовы:20scenes/430XCTestmethods,
32-pathdeltaSHA86e7eafdced3291a8fd38cb054a266a0936a8a96a6e43969bdd49f3cbb945ba1.
UIKitFDpacketAPPLIEDиcoordinatorverified:14/14pathsбезdrift,
ZIPdaac64f977e2bba45612f1ca92cc8063606fa4ae50216f2143c2cd0dccaf3123.
1397inputs,7driver+4FDchecksPASS;actual_ios_fd_pathsобязателендляобоихiOSowners.
20scenes/430XCTestmethods/30sprocessсохранены;Native/framesнеисполнялись.

Последний follow-up `reviews/sdk-symbol-remediation-source-closure.md`:
**8 counterexamples source-closed**, остаётся P2 native Elyx command ingress.
Его исправляет developer/proxy owner `ses_e1f7a723bffeBMTKIuM4Qx6b3m`: routing
authenticated native commands к captured Host owner, сохранение изменений при
archive reload; shared Host/Runtime hunks вернёт координатору.

Search application завершена: все17paths51hunks, включая exports_files послеtrust.
`settings-search-applied.json` сохраняет исходный16-path handoff; CORE_PROBES13,
7driverchecksPASS. Reviewer `ses_e1f1fd562ffeEpJev9Kon2gUEU` выявилR1–R5 выше.
RootClientRuntime, AppDelegate, Core schema metadata и прочие search участки
сейчас у `ses_e1fa49bedffe9T2IHYNLWYNLIj` для их устранения.

**Trust integration APPLIED**: `plugin-trust-level-applied-manifest.json`,28paths,
167sourceassertions,13Host/2UItestsprepared. Native executionpending.
Coordinator затемAPPLIEDпоследнийSearch Tests/Exteraless/BUILDexport; все17searchpaths
теперьjoined. Trustreview `ses_e1f1c511cffeeQHqwH0UJjDrme` завершён: базовая модель
признана source-correct; исправляются три вторичных permission dependencies выше.
АрхивныйиCustomfixcohortвсёещёнефризитсядозакрытияизвестныхP1/P2.

Reset scopes readyиCorecommittedd1df6ad6:3original scopes,17fixtures,publiconeCAS,
explicitcredentialsteps/retryprogress. КоординаторAPPLIEDRootupdate/clear/registration,
BUILDfingerprints иOriginalother.resetSettings→general.settingsResetpreview route.
Независимоеreview `ses_e21807247ffeFnULrI55blC3CT` завершено: дваRSR findings выше.
UI/RuntimeWIP sourcepins ждутфинальногокоординаторскогоregeneration.

| Scope | Owner / границы файлов |
|---|---|
| ELYX-GAP01: bounded .elyx/.eaf inspect/install/load/cache | `ses_e1f7e69c8ffe8uVIgEPrHC2jv6`: Host loader,верхний PluginModel,`__init__`,new `_archives`; common install/UI hunks координатору |
| gen/gen2 + dev-command shape + daemon/native-server lifecycle | `ses_e1f7a723bffeBMTKIuM4Qx6b3m`: proxy/java interfaces,new helpers; `_platform.install`/Runtime hunks координатору |
| Direct hook facade ledger + CORE-F02 send priority | `ses_e243a7152ffeYsQQZoLZXmyT32`: `_platform` hook methods; Host send/query hunks координатору |
| CORE-F01/F03/F04/F05 edit omission,find_class,callback containment,queue cancel | `ses_e25088ca2ffeapc0yZ2vwlbKAh`: `_tl`,`_scheduling`,new reflection helper; install hunks координатору |
| Manager Custom widget materialization / setting aliases | `ses_e21807519ffebI1gU3ny5Wbf92`: `_ui`,`_facades`,PluginSettingsModel/Controller; common Runtime/manager hunks координатору |
| Native trust levels and grant cap/pruning | `ses_e1f70f8b3ffeUtL1662l0wpYzD`: new trust helper,PluginModel нижние PermissionsModel/PluginStore; Host/UI hunks координатору |
| Native settings-search and row routes | `ses_e1fa49bedffe9T2IHYNLWYNLIj`: new index/helpers; common SettingsController/search/Root hunks координатору |
| Original aggregate reset scopes | `ses_e243feabaffewbO5DkO2qNaCMs`: new Core/UI helpers,exact Original scope; общие hunks координатору |

Developer/proxy owner вернулготовыйhdo: constructorbase дляgen/gen2, correctedElyx
command shape иnative listenercontrols. Coordinator APPLIED2-line `_platform.install`,
newPluginDeveloperBridgeExtension иRuntimecomposition; общиеfilesещёworkingtree.
Listenerfixturecompile/run budgets120/10с, process-group cleanup. СтарыйWindowsC
fixture подтверждаетhandleidentity, не актуальныйC-ownerABI; новыйMacgateобязателен.
Native socket Elyx live-sync остаётся explicit отдельным маршрутом.

16.11 native Elyx routing/candidate hdo получен,14sharedhunks APPLIEDкоординатором:
Hosttarget/consentcapture,staticdescriptorinspection,newownerloadretention,
Runtimeingress иtruthfulok=falseprotocol. РеальныйFDprovider+3archivehooksвработе;
`native-elyx-developer-remediation.md:142–206` задаётточныйcontract. Покаprovider
неподключён, compare/changesвозвращаютServiceUnavailableдоstaging. Владельцы
архива/developerсогласовываютissueddescriptor/source-byteauthorityбезpathfallback.

Direct hook owner hdo получен: Python6/6на3.12и3.14 среальнымCdispatcher.
Coordinator APPLIEDврабочемдереве `hook_priority_json` sendmetadata, Host
canInvokeSend/priority-query/sort/before-afterguards и2существующихFakeEngine
fixtures;8новыхHosttestsготовы. Archiveowner уведомлёнобэтихнепересекающихсяhunks.
НовыйобщийHost/Python source snapshot ещёНЕкоммититсядофризаarchive/trust/custom.

Archive иManager Custom/alias owners сдалиreadyкод. Coordinator APPLIEDarchive
picker32MiB/4extensions иCoreIDcodec; APPLIED11 Customhunks(Runtimepageforward/
closeAll,modeltargetRowId,actualfocus,harnessforward,BUILDsourcegroup). 12archive
Pythoncases(+1WindowsOS-symlinkskip),13sourceruntimecases и10Customcasespassedуowners.
Все7trustpatch применены. Новый общийHost/Python snapshot ожидает закрытия
archive/Custom/search/trust findings и native Elyx command ingress.

Независимыеreviewsновыхfixes: `ses_e1fa67f7fffe5rs24AiE2bkk5f` archive,
`ses_e1f405489ffeax73Cv9nGJs0Se` core/hook/dev/proxy,
`ses_e1fa43b5dffe4fy9i3YW3fVcwH` Manager Custom/alias. Source-only; новыйMacgatepending.

Все старые source closures сохраняют собственный scope; новый925-аудит выявил эти
дополнительные конкретные gaps. Их fixes пока НЕвключены в запущенный590ce05b snapshot.
Два General scalar getter дефекта исправлены d7d499f7;30/30 generator/binding tests
наPython3.12/3.14,308-counts276/0/32 и508bindings сохранены.

После текущей сборки: завершить опубликованный native graph, принять готовые SDK
fixes с независимым follow-up, обновить bounded component/native map, выполнить
UIKit gate ипросмотреть реальныеframe/PTS references, проверить и передать unsigned IPA.

Native gate/tooling follow-up у `ses_e25088d28ffem4nSC3FcOP577B`: новыйcomputed
native method map, четвёртый bounded real Swift/C/SDK child для archive,
Darwin developer listener и актуальные sparse/input fingerprints. Визуальная
проверка должна включать фактические math/Pill/map attribution controls после
UIButton.Configuration corrections; frame/PTS acceptance пока отсутствует.

### История: native source и последовательные Mac исправления

**Production build snapshot `78e6d5d8497010fe43dabf0604d020f80aa0556f` published.**
Проверены947frozen productionpaths /102stagedchanges, drift0. ArchiveSHA
`9a0336cedbbaf1fb486b6c0861654281e8cc4f5591421ad1c133052e996f8d97`.
Отчёт: `production-build-freeze.md`; production graph0missing/unresolved,
414runtimepins/3267stagedfiles/12distributions, Fonts/Monet/AdGuard иRust pins.

**Первая fullIPA `43735760029 / 78e6d5d8` завершилась failure в Bazel loading**:
mixed-extension fingerprint glob RichTextEditor требовал отсутствующие `.m` в
Swift-only subtree. Cascading missing targets не были отдельными source defects.
**HEAD e8484ec0** добавляет `allow_empty=True` только этому fingerprint filegroup;
production Swift globs и required-source validation сохранены.
**IPA `43736634873 / e8484ec0` дошла до native compilation и завершилась failure**:
MtProtoKit header nullability, iOS-unavailable homeDirectoryForCurrentUser и Postbox
implicit-strong/inner-weak capture. **HEAD136c946f** исправляет эти3causes, сохраняя
null-unspecified legacy semantics, реальную OS home boundary и capture lifetime.
**IPA43738711102/136c946f запущена**, watcher
`sh_1e02862e9001whe5nGtuL85v6s` → `ipa-136c946f-watch.log`, неpoll.
Maccomponent `43735410090 / cca2d83a` завершился failure: первыйSDKchildPASS,
TLchild прошёл первыеchecks/RootConfig/BooleanSilent, но остановился на flags2
mutation/nestedArrayList assertion. Причина устранена в **HEAD e2a5684c**:
native `user.self` конфликтовал с Python receiver до входа в hooks; positional-only
receiver сохраняет это поле как данные. **5/5 real C SDK checks** прошли на3.12/3.14,
исходные validators/true5 expectations сохранены. Это production Python delta,
не входящий в запущенную IPA e8484ec0. Artifacts скачаны в
`build/artifacts/python-runtime-43735410090/diagnostics/`. Его watcher завершён.
Build owner завершает ОТДЕЛЬНЫЙ nativeTests/
UIKit3+3+2snapshot; его ещё не запускали. Не выдавать запущеннуюIPAзауспешную.

**Compat43737741228/e2a5684c в работе**; watcher
`sh_1e01fac1e001APX46vdHBsRzol` → `compat-e2a5684c-watch.log`, неpoll.
CI43737741228/e2a5684cGREEN. Mac43737993772/e2a5684c остановился на холодной20s
UI-fixtureкомпиляции, доSDK. 136c946f разделяетcompile120s/run25s и переиспользует
process-tree-boundedlauncher. **Mac43738810843/136c946f запущен**, watcher
`sh_1e02927bd001vVfS60oOiR9r0U` → `python-136c946f-watch.log`. Старыеwatchersзавершены.

**Новый checkpoint:** HEAD **`46393e31b26741c6f80ff2f9547a960ad10af5c7`**, published
final portable SDK: **276 implemented / 0 blocked / 32 unsupported**, 308 IDs,
59 source pins и10 receipts проверены по staged Git bytes. Compat
**43726335473 GREEN: 361 pytest / 22 skipped** (57.61s; Swift path job skipped).
Последний Swift gate остаётся **654 Core / 180 Host / 30 Hooks на d8cbdaca**.

**Второй manual Mac gate `43728873627 / 46393e31` завершён failure.** Core теперь
скомпилирован: **663 tests / 42 failures**, 7.513s. Один — различие Darwin UTF-16
Range boundary, остальные относятся к storage/unsafePath/rollback и требуют
проверки системного `/var` → `/private/var` alias. Tools owner исправляет общую
filesystem boundary, сохраняя nofollow/fd ownership. **230cb7c0** исправляет AI
selection/span scalar-boundary validation; исходный падающий assertion сохранён.
Артефакты: `build/artifacts/python-runtime-43728873627/swift-components/`.
Watcher `sh_1dfc772ff001mTu34Z7dk2aAR0` завершён, активных CI watchers сейчас нет.
Новые PNP/Font consumer исправления в working tree не включены в этот snapshot.
Font owner исправил три reported consumers и получил допуск на294 read-only
getter replacements по167файлам; Build owner подключает3 actualconsumer tests.
Root/SDK/BUILD не переписывать старыми composer/font handoff copies.

**PNP01–03 independently source-closed 3/3**:
`reviews/navigation-performance-source-closure.md`. PNP02/03 actual DCT/Subcodec
fixes и9 native fixtures опубликованы в **b06f959b**; PNP01 keyboard/focus +3
fixtures — **19c1a96a**. Native execution/frames ещё не выполнены.
**HEAD `2bac089c`**, pushed:294fontgetter replacements167files иactualconsumer
fixes/3fixtures. **PFM01 independently source-closed** для трёх reported consumers
и точного companion diff: `reviews/font-consumer-source-closure.md`; native/UI
приёмка ещё pending. Остаток implementer work — Darwin storage и final
BUILD/recording graph; новых feature-волн нет.

**Последний HEAD `96bff39e89dc889d410821242139d78339c70185`**, pushed: coherent
Darwin storage fix —5 production boundaries +7 regression fixtures. OS aliases
имеют root-prefix pin; suffix/leaf остаются nofollow/fd-owned. Старые assertions и
TBF transaction/ownership bodies сохранены. Handoff: `darwin-storage-remediation.md`.
**Compat43732308228 GREEN: 661 Core / 180 Host / 30 Hooks**
(7.669/4.613/0.254s). Его watcher завершён.
**Третий Mac `43732590856 / 96bff39e` завершён:** **671 Core tests PASS**,
Host/Hooks PASS, Foundation UI/TL и Java codec PASS, **23 HNS scenarios PASS
(1.624s)**. Настоящий Swift/CPython engine probe также PASS:2 OWN_GIL workers,
isolated globals/handles, exception/bootstrap-failure recovery, один finalize.
Полный run остановился на первом SDK child: pre-bootstrap profiler обращался к
`BridgeBackend` во время multi-phase инициализации C-модуля. **HEAD a9afcb79**
исправляет только observer; 2 regressions Python3.12 и actual C-extension import
под profiler наPython3.14 прошли. Native3-child execution требует нового запуска.
Всеартефакты: `build/artifacts/python-runtime-43732590856/`.
Watcher `sh_1dfec362a0016LVibdtC0Phs0b` завершён; активных CI watchers сейчас нет.
После observer-fix **Compat43734000553 / a9afcb79 GREEN**; watcher завершён.
**Четвёртый Mac `43734307283 / a9afcb79` завершён:** первый настоящий
Swift/C/CPython SDK child прошёл. Второй TL child не смог открыть helper: локальный
JSONEncoder экранировал `/` как `\/` внутри Python-литерала. **HEAD cca2d83a**
передаёт quoting в существующий `PluginRuntimeScript.quote` (общий для TL/HNS
helper loader). Диагностика: `build/artifacts/python-runtime-43734307283/`.
Mac watcher завершён. **Compat43735105583 / cca2d83a GREEN**.
**Пятый Mac `43735410090 / cca2d83a` завершён failure**, причина/owner указаны
в верхнемcheckpoint. Активен только полный IPA watcher43736634873.
Darwin alias boundary **independently source-closed**, без оставшихся P1/P2 в
пятифайловом scope: `reviews/darwin-storage-source-closure.md`. Mac rerun подтвердил
исправление execution: все прежние Core failures устранены.

- **HEAD `4476f853`**, pushed: основной native source/resource cohort — **724 файла**.
  BUILD/MODULE/native-test map намеренно оставлены Build owner для финальной стыковки.
  Целый Postbox import/access checker прошёл перед commit; pinned license bytes и
  исторические patch contexts сохранены без изменения их содержимого.
- **Последний Swift GREEN: `43724840744 / d8cbdaca`: 654 Core / 180 Host / 30 Hooks**
  (10.791 / 4.768 / 0.450 s). Включает все новые Core layout/font/swipe/Monet/
  performance policies, typed legacy imports и исправленные Cloud async fixtures.
- **Полный Linux GREEN: `43723260382 / eb44fd9c`: 350 pytest / 22 skipped,
  628 Core / 180 Host / 30 Hooks.** Ранее CI переписывал derived inventory metadata:
  SDK теперь использует canonical consumed-contract hash + 55 raw source pins.
  Две соответствующие обновлённые parity receipts также доставлены в eb44fd9c.
- **Mac `43723262961 / eb44fd9c` — failure на Core test compilation.** Реально прошли
  Foundation UI/TL fixtures, Java→Foundation TL **7 cases** (4.237s compile / 0.864s
  test), Mac Host/Hooks. Единственные compiler errors — два `DispatchSemaphore.wait`
  в async Task у `CloudWriteAdmissionTests`. **`4aac68b3`** переносит синхронные
  writer gates на отдельную DispatchQueue; Linux execution уже green. На этом Mac
  run **не дошли** до 23 HNS scenarios, real Swift/C/CPython 3-child gate, C219 и
  device/iOS-simulator steps. Артефакты: `build/artifacts/python-runtime-43723262961/`.
- Все source joins пяти portable adapters применены: Font/Layout root/registration,
  Swipe reveal/pager/Cloud mapping, Performance native clocks/energy/Root и Monet
  theme/selection/replay/extension registration. SDK lead финализирует новый catalog
  (**276 implemented / 0 blocked / 32 unsupported** на Font/Layout checkpoint).
  Старый Mac snapshot этим результатом не переименовывается.
- CMC03 persistent-draft terminal admission и CMC05 complete media Schedule DTO
  **independently source-closed 2/2**, без оставшихся P1/P2 в этих сценариях:
  `reviews/chat-final-source-closure.md`. Их fixes опубликованы в native cohort;
  native XCTest/frames ещё требуют Apple gate.
  Feed/Player **FU01–04 independently source-closed 4/4** в
  `reviews/feed-player-final-source-closure.md`; все7 in-flow Save вызовов имеют
  тот же permit/reference и success receipt. ASC01 active crossfade reset и TLN-F01/F02 independently
  source-closed; source closure не заменяет Apple execution/frames.

#### Текущие последние действия

| Scope | Owner |
|---|---|
| PNP01 retained-controller keyboard inset при layout adoption | Sourcefix committed19c1a96a; native execution pending |
| PNP02/03 actual DCT/Subcodec elapsed stepping | Sourcefix committedb06f959b; native execution pending |
| Darwin storage alias/ownership execution failures | `ses_e243dc98dffe0Q86bXmQPlA0ju` |
| PFM01 actual consumer refresh +294 global getter deltas | `ses_e20a85c31ffe092S8uLDOcPZv2` |
| Final SDK scalar catalog / все source pins после portable joins | `ses_e25088ca2ffeapc0yZ2vwlbKAh` |
| Final BUILD/import/staging/native-test map, serial 3+3+2 recording | `ses_e25088d28ffem4nSC3FcOP577B` |
| Readonly new Font/Monet review | `ses_e2063d144ffeMhXK6RfIVtI74R` |
| Readonly CMC final / Feed-Player final | `ses_e214287a0ffeF3b5lXhJ1l2jNu` / `ses_e21be714fffeFhsVulQ5XTiIuh` |

Native harness теперь содержит **3+3+2** explicit scenarios; DEBUG Composer factory
coordinator applied. Build owner подключает final-visual filegroups/resources и
native tests. Никакой полной IPA/harness сборки пока не запускали. Предыдущие
watchers завершены; актуальный второй Mac watcher указан выше.
Проверенная unsigned IPA всё ещё build23 / `43635233046 / 68bb1adf`.

### Исторический checkpoint: SDK cohort и portable adapters

- **HEAD `ffdb2833d68bbb7c0f51e684f109a494999a8e21`, pushed.** Опубликованы Python
  SDK/virtualjava, Config308, TL schema/codec, UI helpers и минимальные actual-root
  source dependencies. Все **56 SDK source pins** совпали с staged Git blobs.
  Автоматический Compat должен проверить Python cohort; результат ещё не прочитан.
- **Последний полный Swift GREEN: `43717372459 / 0ceafb7b`: 622 Core, 180 Host,
  30 Hooks** (7.567 / 4.639 / 0.356 s). Включены TBF01–04 portable checks,
  Filtering notification admission и прежний Cloud/Host набор. Darwin-only swap
  fixtures и UIKit этим запуском не выполнялись. `43c46497 / 43716703817` также
  GREEN: 609 / 180 / 30, включая шесть CAF02/03 tests.
- **Source-closed независимыми reviewers:** TBF01–06
  (`reviews/tools-source-closure.md`), HNS-F01–04 (`host-native-source-closure.md`),
  PFR01–05 (`privacy-retention-source-closure.md`), SDK01–09 (`sdk-source-closure.md`),
  AIAF01 (`ai-source-closure.md`). Новые native/CPython/UIKit исполнения ожидаются.
- Все 6 файлов / 13 hunks `chat-review-integration.patch` применены, включая
  pending-edit typed admission и реальные custom-content adapters. Forward packet
  применён Chat owner, Gallery packet — Feed owner. Feed завершает конечные guards
  в SaveToCameraRoll/ShareControllerNode. CMC/TLN/CAF/Avatar/IDSF focused closures
  выполняются в background; implementation у этих reviewers readonly.
- SDK snapshot **272 implemented / 4 blocked / 32 unsupported**, 308 overloads.
  Последний source check aligned; Java 12/11 + SDK49/49 tests, real C transport
  на Python3.12. Блокировка четырёх API сейчас соответствует отсутствующим native
  TabletMode/UseSystemFonts, а не фиктивным defaults.
- Все **567/567 source receipts**, 30 modules, 925 SDK symbols сведены в
  `docs/parity/`; verified promotions=0. Исторические data snapshot pins сохранены;
  обновление всего inventory после окончательной сборки не должно переименовывать
  старые source/native evidence.

#### Оставшиеся переносимые policy adapters

Для полного client scope переданы пять конкретных пробелов из reconciliation:

| Реализация | Owner / разрешённые границы |
|---|---|
| ChatSwipeAction primary reveal/folder policy | `ses_e243f0df6ffeyOgNnZ6UAfr3px`; новый Core helper, ChatListItem reveal; остальные common изменения patch |
| Performance class 0/1/2/3 | `ses_e243dc98dffe0Q86bXmQPlA0ju`; новый Core/native energy policy, старые TBF файлы frozen |
| Forced layout Auto/Tablet/Phone | `ses_e243f7abcffeGuUNpnkq2GkoQa`; новый Core/Display helper, Root/registration patch; Avatar frozen |
| System/bundled font family | `ses_e20a85c31ffe092S8uLDOcPZv2`; Font/helper и pinned resources, Root/BUILD patch |
| Telemone/Classic native Monet theme policy | `ses_e20a6e795ffenGepIW4H0Buuho`; отдельные palette/theme helpers, common/BUILD patch |

Эти новые настройки ещё не зарегистрированы и не входят в опубликованный SDK
snapshot; compositor не должен подмешивать их в текущий Mac gate до стыковки.
Build owner `ses_e25088d28ffem4nSC3FcOP577B` заканчивает component input preflight
и final native-test map (включая PFR10/Chat18). Code/SDK/runtime текущего checkpoint
нужно проверить настоящим CPython на Mac; новое полное IPA — после native joins.

Активных CI watchers на этой точке нет. Manual Apple dispatch ещё не отправлен.
Последняя проверенная unsigned IPA — **build23 / 43635233046 / 68bb1adf**.

### Исторический checkpoint: green Core/Host и стыковка

**Следующий проверенный срез:** `9c409eb88541ba948ad593f9096b8f4a3485de74`,
**CI43711634580 GREEN: 595 Core / 174 Host / 30 Hooks** (5.768/4.620/0.253s).
Он включает Core Tools/Appearance/AI-native/Sticker и пять HNS-F02 Host read tests.
`6f718b11 / 43709697267` ранее скомпилировал production Core, но поймал запрещённый
Sendable-capture URLProtocol в fixture. Исправление захватывает immutable late
delivery/client/url, сохраняя настоящий поздний callback; тесты теперь прошли.

**HEAD `93a1badcb0ef414ca5218cf938e3b8e2be47a828`, pushed:** Core
ExteraConfigCompatibility + tests. **Compat43712394860 GREEN: 603 Core / 174 Host /
30 Hooks** (6.858/4.643/0.254s). Watcher `sh_1df1e6fc5001m3f7zFzwlVc79N` завершён.
Активных CI watchers на этой точке нет. Cloud/API follow-up
`ses_e216fc451ffe1XvLfuku0EKr47` по просьбе пользователя переведён в background;
результат ещё не получен, не ждать и не poll.

HNS-F01 TL4 shared hunks и HNS-F02 Runtime/harness read token forward уже applied
coordinator. UI F01/F02/TBF06 source23scenarios получены. AIAF01 independently
source-closed в `reviews/ai-source-closure.md`. AP follow-up оставил4 avatar P2;
исправляет Appearance owner. Gallery CMC packet applied Feed owner, terminal
SaveToCameraRoll/ShareControllerNode guards разрешены ему для окончательного FU02.

Новые полученные follow-up: SDK01 P1 / SDK02–09 P2, Tools TBF01 P1 / TBF02–06 P2,
IDSF01/02 P2 и AIAF01 P2. Они распределены, прежние reports сохранены. AIAF01 уже
получил source fix + real Postbox fixture; native execution pending. SDK06–09 Java
fixes готовы: 12 Python3.12 tests (включая matching C transport), 11 на3.14; по34
существующих SDK/TL/virtualjava tests passed на обеих версиях. Native TL-codec
контроль подготовлен отдельно. Source freeze — `sdk-java-remediation.md`.

Runtime SDK05 coordinator fixed: immutable `PluginConfigAuthority`, atomic
`pinnedSet(wanted:installed:)`, authority check в самом writer; добавлены3 native
fixtures. Эти три Swift-файла не перезаписывать старой SDK/Runtime копией.
SDK01 Root registration — App owner; SDK02/03/04 + native-probe F03/F04 — SDK lead.
Новая Java роль завершена: `ses_e20fce672ffeVKpwo5NAAonQbK`; её файлы frozen.
TBF01–04 — Tools owner, TBF05 Runtime startup patch — Host owner, TBF06 fixture — UI.
PFR01/04/05 native owner APIs получены; App owner завершает typed startup/UI join.
CMC Rich и Media helper cohorts получены; Gallery/Forward packets применяют Feed/
Chat owners. Core/Hook/SDK source receipts не являются новой Apple IPA.

- **HEAD `6f718b1108b9f90b5d498e07ee324325842bbe5d`, pushed.** Его автоматический
  Compat CI ещё не прочитан. Добавлены завершённые Core Tools/Appearance/AI policy/
  Stickers срезы, включая coordinator registration для четырёх Tools modes и
  Appearance settings sections.
- **Последний полный GREEN: 43708260304 / `7d04a35a3612a2dc32dba6fb54744e38c07cabe9`:**
  **545 Core (6.908 s), 169 Host (4.838 s), 30 Hooks (0.654 s)**. Cloud retry и
  CA01/03/05/06 Core tests, settings48, Identity expiry9 вошли. Это не native UIKit.
- Исправления двух test-only проблем HNS: реальный unload entry — `unload()`, не
  `unload_json`; worker identity определяется по `Thread`, без неверного имени
  `plugin-*`. Expired TL scope ожидает typed `superseded`. Assertions Python
  non-entry, cleanup и отсутствие unrelated timeout victims сохранены.
- **Прежние 56 receipt gaps: 56/56 теперь присутствуют, остаток 0.** Readonly join
  actual fragments проверен. Основной inventory/reconciliation ещё надо обновить;
  ни одного verified/ported promotion. Tools —43, Appearance —78, Chat —137 rows.
- Source Root/App/Cloud C1–C6/PR02/03/05/14, tracking/canonical migration и common
  Chat optional-sound signatures применены. Native HNS Runtime patch применён SDK
  owner; coordinator добавил все три HNS06/07 handoff insertions и actual lease
  constructor capture. HNS-F01/02 остаются ниже.
- **TLN04 — все11 hunks applied** поверх PR02/C5/CA04. **TLN05 — все5 Enqueue hunks
  applied**, включая supplied permit после bot authorization и до native writes.
  EnqueueMessage передан Chat owner для CMC02 typed-admission/draft fix; не затереть
  `tlCommit:`. CA04 все Network/Runtime Swift logging hunks applied, nested Rust
  postimages сохранены. Legacy text несёт worker ancestry и captured account identity.
- AP common Help/Premium/Stickers и четыре Tools mode consumers applied coordinator
  (MediaEditor bitrate, voice-processing fallback, group audio bitrate, safe RPC
  method/code buffer). IDS02 Avatar/PeerAvatar display-filter hunks applied; AF05
  History renderer теперь читает единый effective-target resolver.
- CMC12 coordinator source fix: Browser root подключён к modal и horizontal gates;
  исправлен NSNumber-pointer-as-Bool getter `disablesInteractiveModalDismiss`.
  Два небольших native fixture ожидают BUILD/execution. Native/frames не пройдены.

#### Открытые последующие findings / актуальные владельцы

| Findings / стыковка | Owner |
|---|---|
| HNS-F01 UI batch guard; HNS-F02 Runtime read patch | `ses_e243ae7aeffeUQ5vuAwd50ZLES`; Runtime прямые записи пока coordinator |
| HNS-F01 TL ticket/commit execution guard | `ses_e243a7152ffeYsQQZoLZXmyT32` |
| HNS-F02 expected-owner/settings-read envelope | `ses_e25088ca0ffeSZG3hnR62kAl3y` |
| HNS-F03/F04 native-probe Set/array и post-retirement denial; final Config regeneration | `ses_e25088ca2ffeapc0yZ2vwlbKAh` |
| PFR01/02/03/04 versioned unavailable, startup/error/retry/disposal | App `ses_e23c3fd88ffeMRAQjFJMkGEi7B`, Retention `ses_e23d7951effep2RWsy5h8oFA3t` |
| PFR05 retired retained-resource terminal failure | Retention `ses_e23d7951effep2RWsy5h8oFA3t` |
| CMC02/05/11/13/15 send/draft/edit/call/Pangu | Chat `ses_e243f0df6ffeyOgNnZ6UAfr3px` |
| CMC01/06/07/08 rich Date/selection/parser/paste | `ses_e212100a0ffeaWlJpdRHM9P5LT`; Date/Format/paste sections, Chat owns separate edit/send sections |
| CMC03/04/09/10 fresh selection/media protection, exact medium/time | `ses_e21210021ffeduxuyWRAPgaO8R`; GalleryController/Footer/Share patches to coordinator/Feed |
| FPP-FU01/02/03 window frontier, descendant export permit, stable cells | Feed `ses_e23c54cb8ffe3nH7QqgmL29dSQ` |
| FPP-FU04 + CMC14 | Player source fixes received; `docs/player-remediation.md`, tests/frames pending |
| Final BUILD/test/harness recording integration | `ses_e25088d28ffem4nSC3FcOP577B` |

AF01–06, IDS01–08, AP01–11, Tools TB/CA source fixes получены; независимые follow-up
reviews выполняются. SDK-specific reviewer — `ses_e21159039ffeH1u3rPuPRRUc8r`.
Config old frozen receipt **260/16/32**, регенерация идёт по полученным final defs;
Source-check drift не считать успешным check. Три native SDK child по30s подготовлены.

Harness source получил `feed-render/player-render/pill-render` и HNS action authority.
Build owner подключает две последовательные группы по3 процессов к одной сборке.
Native target map был19 targets/139 methods; поздние PR/AF/IDS/CMC additions ещё
нужно включить в финальный map. Никакого Mac/IPA/harness dispatch пока не отправлено;
последняя проверенная IPA — build23. Подпись/физический iPhone/APNs требуют пользователя.

### Исторический срез после первых повторных ревью

- **HEAD `f99909b58968b69dfb57132db9dd84d2e28889cc`, pushed.** Compat
  **43700711108** скомпилировал весь Core: **485 tests, 1 failure, 7.603 s**.
  Единственный failure — повторный Cloud preview после ожидаемого CAS conflict:
  `CloudLegacyImportTests.testLegacyOverlayCASPreservesAbsentUnrelatedFieldsAndRejectsChangedPresence`.
  Cloud owner исправляет actual retry/reload, сохраняя storage-error guard.
- **45 Settings, 75 AI, новые Pill/Player/Hidden/Filtering regressions прошли** в
  этом запуске. Весь run остаётся red. Последний полный green —
  **43698196787 / dcc13004: 390 Core + 147 Host + 24 Hooks**.
- `ddc25d69 / 43699189463` раньше остановился на отсутствующем committed
  `ChatDoubleTapAction`; зависимость вошла в `f99909b5`. Остальной Chat phase-2
  Core/source пока у Chat owner. Canonical AI reader уже использует
  `chats.showTextTranslate`, отдельное AI definition удалено; Root migration
  делает App integrator.
- SCF01/02 closed по независимому source follow-up, их 45 tests уже исполнены.
  Новый **SCR01 P2** (quarantined presence/public cache) исправляет Settings owner.
  AICF01/02 fixes вошли в AI75; final AI follow-up ещё выполняется.
- Новые reports: **HNS01–09 = 6 P1/3 P2**, **PR01–14 = 5 P1/9 P2**,
  **TLN01–11 = 3 P1/8 P2**. Они открыты до fixes/re-review, не закрываются наличием
  предыдущего green. Source-independent reports сохраняются в `reviews/`.
- Feed FPP02–05 + 616-message bound/CAS завершены, Core **8 файлов FROZEN**:
  `feed-core-frozen.sha256`. Player FPP03/06/07/08 и Pills FPP09/10 source готовы.
  Их native regressions подключает Build owner; UIKit/frames ещё pending.

#### Текущее владение remediation — приоритетнее исторических таблиц

| Scope | Owner / работа |
|---|---|
| Host lifecycle/EventQueue/Watchdog/SubinterpreterManager/ExtensionPoints | `ses_e25088ca0ffeSZG3hnR62kAl3y`: HNS04 Host API, HNS06–09; отдельный batch capability, общий ingress budget, bounded terminal drain |
| NativeService* + native PluginServices | `ses_e23dc0954ffeEMh9n0izZtjJbQ`: HNS02 cleanup и HNS03 worker-time revocation |
| PluginUI / PluginSettingsController, Runtime **только patch** | `ses_e243ae7aeffeUQ5vuAwd50ZLES`: HNS01/04/05 + UI-часть HNS02 |
| ExteralessPluginRuntime / SDK/config/probes | `ses_e25088ca2ffeapc0yZ2vwlbKAh`: Config58, HNS04 SDK account scope, real SDK cleanup fixture, TLN06/07/08/11 |
| Core Tools/schema/backup + Tools UI | `ses_e243dc98dffe0Q86bXmQPlA0ju`: TB01–06, HNS01 evidence contract, 14 receipt gaps |
| Native TL + Hooks submission order | `ses_e243a7152ffeYsQQZoLZXmyT32`: TLN01/03/04/05/09/10; Network/TLNetworkRequest/Enqueue shared changes возвращает patch |
| BridgeServices/PluginServiceModels/PluginTLInvocationOrigin, legacy TelegramPluginServices | **Coordinator**: TLN02 applied-source, 3 new Host tests; final send теперь использует единый `exteralessTLSendText` |
| AppDelegate/ClientRuntime/Account/Network/Cloud C1–C6 + extensions/ApplicationContext | `ses_e23c3fd88ffeMRAQjFJMkGEi7B`: composition, async pre-account readiness, Tools/Cloud bindings, PR03/05/14 |
| PrivacyExtras helpers/summary/filtering/panic | `ses_e23d72be2ffeRJmlhKY4LBsZxV`: PR01/06/12/13 + PR03 helper contract; A–D closed-source |
| PrivacyPolicy/Observations + AccountViewTracker observation block | `ses_e243e9ec3ffeNQLS1mE6CHrtur`: PR02/04; TLNetworkRequest privacy hunk отдельным patch |
| Native Retention/helpers/UI adapter | `ses_e23d7951effep2RWsy5h8oFA3t`: PR06–11 + PR05/14 process-readiness contract |
| Core Cloud + tests | `ses_e23a799e4ffexGANrzzE3WW4C9`: CI retry failure; независимый Cloud/API reviewer `ses_e216fc451ffe1XvLfuku0EKr47` |
| Core Settings + tests | `ses_e243feabaffewbO5DkO2qNaCMs`: SCR01 |
| Build/BUILD/workflows | `ses_e25088d28ffem4nSC3FcOP577B`: native regression targets и execution step в UIKit workflow; tracked Rust patch уже готов |

Chat/Appearance продолжают свои fixes/receipts и Identity remainder: ChatController —
Chat owner, ChatListItem/AvatarNode/PeerAvatar — Appearance owner; ChatListController
Identity hunk уже применён Feed owner. AI visibility owner допущен к трём локальным
AI-button conditions в ChatTextInputPanelNode и summary gate в InstantPageLayout.

Независимые дополнительные reviews: AI final `ses_e22049f6dffeSiz0Jp8oE1BVLX`,
Identity/Dialogs/Stickers `ses_e216bbb54ffeg23Z0asUbG0jyX`. SC recovery report уже
получен (`settings-recovery-followup.md`), новый SCR01 открыт. Точные settings API —
`host-settings-execution-contract.md`: **account = Int32 SDK slot**, не record ID.

На этой точке все CI watchers завершены. Новые Mac/IPA/harness dispatch ещё не
отправлялись. Последняя проверенная IPA — build 23; GitHub API secrets установлены.

### Предыдущие срезы и история передач

**Следующее обновление:** HEAD **`ddc25d69`** — добавлен frozen Core Cloud/ClientAPI/
Retention (31 файл), его CI ещё не прочитан. Предыдущий полный Linux gate
**43698196787 / dcc13004 GREEN: 390 Core + 147 Host + 24 Hooks**. Host maintenance,
native service queues, worker gates и TL transformations теперь реально прошли
Foundation/FakeEngine tests; UIKit/network/CPython execution этим не подтверждён.

Независимые follow-up: SC01–08 closed, но два новых P2 SCF01/02 исправляет settings
owner. AI04/05/12/17 closed; AICF01/02 (HTML fallback, Android-import presence)
исправляет AI Core owner. Старые reports неизменны. Native AI source-remediation
88 hunks/29 files применена, остаётся Build-сегмент и subsequent native review.

Root/AppDelegate/Cloud C1–C6 + pre-account async settings bootstrap снова у
`ses_e23c3fd88ffeMRAQjFJMkGEi7B`. Runtime Config/global58 bindings у SDK-owner;
не менять эти два composition roots одновременно. Retention применяет оставшиеся
state/privacy/UI patches; Account+Root сегменты переданы app integrator, enqueue —
Chat owner. NetworkMaps/Rust/passive RTT уже applied. Build подготовил strict outer
patch для трёх nested Rust файлов и подключил его к preparation/Make/harness/tests;
эти новые build файлы ещё нужно включить в outer commit.

Новые независимые reviews: Host/native services `ses_e21807519ffebI1gU3ny5Wbf92`,
TL/network `ses_e218073c2ffe5h9GuhA8oC9Eki`, privacy/retention
`ses_e21807247ffeFnULrI55blC3CT`. Другие remediations продолжаются по своим IDs.
SDK native probe source готов (два процесса ≤30 s); перед запуском Mac дождаться
окончательного Config binding/source commit и целостного fingerprint.

- HEAD **`dcc13004`**. Проверенный Core snapshot **`e59bd30a`**, CI **43696986849**:
  **390 Core / 90 Host / 16 Hooks PASS** (Core 4.316 s). Включены 42 settings и
  73 AI tests после SC/AI Core fixes, новые DNS/maps/dialog/identity/emoji policies.
- Host/NativeServices/TL/Maintenance source закоммичен в **`20166b2c`**; CI
  **43697451186** скомпилировал Host и упал только на устаревшем ожидании install
  после terminal stop. `dcc13004` требует `notRunning` и отсутствие нового файла/
  модели, сохраняя исходную late-creation проверку. Результат нового CI ещё не получен.
- Source SC-01…08 и AI-04/05/11/12/13/17 fixes опубликованы; независимые follow-up
  reviewers продолжают проверку. Native AI remediator **применяет** 89 hunks / 30
  файлов; это не готовый native/visual pass.
- **По прямому запросу пользователя установлены GitHub Actions secrets**
  `TELEGRAM_APP_ID` / `TELEGRAM_APP_HASH` в текущем repo, оба имени проверены
  15.11.2026 09:09 UTC. Их значения не включать в исходники, logs или handoff.
- Дополнительные findings: Tools **TB-01…07 (2 P1/5 P2)** исправляет Tools owner;
  Feed/Player/Pills **FPP-01…10 (3 P1/7 P2)** разделены между Chat/Feed/Player/Pill
  owners; Appearance **AP-01…11 (11 P2)** исправляет Appearance owner. Исходные
  reviews сохранены. TB-07 readonly settings path уже исправлен coordinator.
- `ClientSettings.shared` в main/share/notification получил фактический app-group
  container как `durabilityRootURL`. PrivacyExtras owner передаёт его private store.
- `settingsDirectoryURL()` не создаёт каталог; startup recovery и schema freeze
  Runtime переведены на него. Старый creating accessor сохранён для обычных SDK writes.
- Native callback-origin из TL pipeline захватывается на C worker до Task и
  передаётся в Host invocation. Upload-origin patch применён TL owner.
- Все UI common menu hunks применены coordinator. Runtime включает UI, client
  settings, TL, NativeServices с двумя publishers, Pills и harness scope factories.
- **Nested Rust изменения требуют tracked patch:** внешний gitlink
  `telegram-ios/third-party/mtproto-engine` остаётся `da4b2170`; изменены только
  `resolver.rs`, `session_runtime.rs`, `worker.rs`. Build owner готовит strict
  base/post-image patch application для CI/local/harness. Не коммитить непубличный
  nested hash и не сбрасывать эти файлы. Аудит других outer gitlinks: чисто.
- Source receipts сверены в `docs/parity/wave-2-reconciliation.*`: 511/567 выбранных
  feature rows, 56 receipt gaps; SDK308 =179 implemented/102 blocked/27 unsupported.
  SDK owner закрывает global compatibility namespace, atomic snow и manager bindings.
- Все full Apple builds используют **`xcode-27` / Xcode 27.1**. Baseline job подтвердил
  этот label и GitHub Actions runner. Harness owner исправляет прежний выбор26.6.

Текущие owners дополнительных fixes: native AI `ses_e21e26903ffettUNcrNabLYO1D`,
Tools `ses_e243dc98dffe0Q86bXmQPlA0ju`, Feed `ses_e23c54cb8ffe3nH7QqgmL29dSQ`,
Player `ses_e23c59fa3ffeQ9l6CFXD6gAPU7`, Pills `ses_e23c4f365ffein8sxkRXQqqmH1`,
Appearance `ses_e243f7abcffeGuUNpnkq2GkoQa`, extras helper
`ses_e23d72be2ffeRJmlhKY4LBsZxV`, SDK/config `ses_e25088ca2ffeapc0yZ2vwlbKAh`.
Core fixes не означают closure нативных/harness/review gates.

- **HEAD `b1424e10`**, последний Linux gate **43693106297**: **280 Core + 89 Host
  + 16 Hooks passed**, Core execution 2.689 s. Совместная регистрация публичных
  domain schemas также проверена. Это не UIKit/native-service execution.
- `9222140b` добавил завершённые Foundation appearance/tools/pills/player/feed/
  filtering/hidden-account срезы и C remediation. Python compat job этого commit
  (`43691591367`) success. Swift-повтор исправил NSObject.hash collision
  (`b50d63e6`), throwing Pill fixture (`e89009a4`), затем реальную потерю base letters
  при Unicode deletion (`b1424e10`); теперь оба текстовых пути строят UTF-16 projection.
- C P2 **независимо закрыт**, `reviews/native-owner-token-followup.md`. Новых P1/P2
  в C не найдено. Native author's свежий Windows probe — **219 calls**, 27 terminal
  entry refusals и 2/2 freed payloads. Reviewer не повторял весь 219-call probe из-за
  изменённых parallel SDK/validator fingerprints; final native CI обязан собрать
  актуальные inputs заново.
- **Открытые review findings:** Settings SC-01…08 (1 P1, 7 P2), AI AI-01…18
  (5 P1, 13 P2). Исправляют исходный Core/settings owner, AI Core owner и отдельный
  native-AI remediator. Последний green CI предшествует этим fixes.
- Все первые domain source-handoffs получены; завершается применение shared hunks
  и независимое ревью. Ни полной новой IPA, ни записанных UIKit frames пока нет.

### Текущие передачи, приоритетнее старой таблицы

| Владение | Session / задача |
|---|---|
| ClientSettings / value / definition / secrets / tests + ClientSettingsBridgeExtension | `ses_e243feabaffewbO5DkO2qNaCMs`: SC-01…08 remediation и optional strict valueShape |
| Core AI + provider settings editors + plugin-review controller | `ses_e243e30eeffevvi6PoeDOI6HKb`: AI-04/05/11/12/13/17 fixes |
| Native AI integration/adapter/actions/results/rich mapper/Speech + Core AI engine helpers | `ses_e21e26903ffettUNcrNabLYO1D`: остальные AI findings; common changes возвращает patch |
| Network/Account/UpdateGroup/UpdateMessageService/AccountStateManagementUtils/RequestEditMessage + PluginHost/ExtensionPoints | `ses_e243a7152ffeYsQQZoLZXmyT32`: применяет TL shared mutation pipeline; сохраняет maintenance/gates |
| AppDelegate/ClientRuntime/SharedAccountContext/ApplicationContext/Passcode/NotificationService/AccountViewTracker/list projection/reaction/blocked/download hooks | `ses_e23c3fd88ffeMRAQjFJMkGEi7B`: privacy-extras integration; Root недоступен coordinator до возврата |
| Runtime/Manager/PluginSettings + PluginUI | `ses_e243ae7aeffeUQ5vuAwd50ZLES`: native services/TL transforms, schema/recovery/manager prefs, harness factories |
| GalleryUI UniversalVideoGalleryItem + Gallery subtitle bridge + ToolsIntegration | `ses_e243dc98dffe0Q86bXmQPlA0ju`: реальная subtitle clock/layout/menu/PiP integration |
| ChatController/history/list/avatar/PeerInfo story guards, узкие next/story LoadDisplayNode sections | `ses_e23a8d83effeF78mYrykWv5M0P`: dialog shared hunks; state pin-echo отдаёт TL owner |
| MtProtoKit/Rust DNS/stream host + location/map/external-navigation | `ses_e23a80a9cffeBJo6p90oWskp2w`: NetworkMaps native hooks, Network/Root hunks отдельно |
| Non-common emoji/font/picker/GIF/recents/reaction + local favourites | `ses_e23aa4ae2ffeh4R3TtaQBhKaje`: применяет готовые 37 anchors и Tools favourites |
| Identity non-conflicting name/date/profile presentation seams | `ses_e23a86f80ffep0m8LJJWGDJPxo`: 22 IDs / 152 anchors, занятые shared sections отдаёт отдельным patch |
| Cloud legacy mapping/credentials | `ses_e23a799e4ffexGANrzzE3WW4C9`: Android cloud import, согласование AI origin-bound credential API |
| Plugin pill bridge + RTT audit | `ses_e23c4f365ffein8sxkRXQqqmH1`: Runtime pill services, stable ID mapping; existing Core frozen для CI |

Chat phase 2 / SDK / retention / build / UI harness сохраняют ранее выданные scopes.
App integration не должна дважды вычитать filtered unread: `ChatListNodeLocation`
уже использует `exteralessDialogProjectList` → `exteralessFilterChatList` перед sorting.
Первый clean P2 C pass не равен повторному execution текущего SDK snapshot.

### Новые reviewers

- Settings: `ses_e22059302ffeTTkt6sccLHsEbl`, report получен, ожидает fix/re-review.
- AI: `ses_e22049f6dffeSiz0Jp8oE1BVLX`, report получен, ожидает fix/re-review.
- Tools/backup/files: `ses_e21be726affeNDjsq2yXYN3qeh`.
- Appearance: `ses_e21be7259ffetV07BXfehvmYGO`.
- Feed/player/pills: `ses_e21be714fffeFhsVulQ5XTiIuh`.

### Применённые после предыдущей точки hunks

- Feed AccountContext entry, root tab replacement/badge + appearance re-composition;
  feed update раньше appearance. Player/Pill root integration, Channel feed tab menu,
  pill header panel/visibility и external Contacts/Settings fallbacks.
- Native PiP swipe checks в Gallery; subtitle интеграция теперь у Tools owner.
- `Display.nativeWindowHostView(windowScene:)`: scene до root/controller keyboard.
- Harness BUILD filegroups/framework visibility внесены build-owner; manager/settings
  factories — у UI-owner. Harness workflow исправляет его author: **full app всегда
  собирался на `xcode-27` / Xcode 27.1**; `macos-26` / 26.6 предназначен для runtime
  component tests. `UIView.reservedRegions` требует настоящего нового SDK.
- Exact raw C-owned request JSON сохраняется при extension dispatch, предотвращая
  лишнее округление чисел до strict ClientSettingValue decoder. Forged legacy
  identity fixtures всё ещё получают authoritative native pluginId.

Ни одного активного IPA dispatch/watcher на этой точке. Новые MAC gates запускать
после закрытия P1 и стыковки текущего SDK/Host/input fingerprint.

## Проверенные снимки

| Снимок | Проверка | Результат |
|---|---|---|
| `68bb1adf` | Full IPA `43635233046`, build 23 | 67 unsigned ARM64 Mach-O, 55 Python frameworks, 1071 Python resource, 6 extensions; локальная повторная проверка SHA/layout/seal |
| `496d4262` | Linux `43645893132` | 15 Core settings + 79 PluginHost + 16 PluginHooks tests |
| `b274f4de` | Linux `43649411038` | 45 Core settings/chat/feed/link tests + 79 PluginHost + 16 PluginHooks; Core suite 0.478 s |
| `4b3f7064` | Linux `43653040458` | **122 Core + 89 PluginHost + 16 PluginHooks**, все passed; Core 1.428 s. Включает 28 settings/CAS, 40 AI и privacy-policy fixtures |
| C owner-token WIP | Windows CPython 3.12.10, debug allocator | 213 C calls, включая прежние 169; 24 bridge tests passed / 1 skipped; iOS повтор ещё нужен |

HEAD `4b3f7064`: Core/AI/privacy, settings batch/CAS, bridge discovery и bounded
native-effect leases закоммичены. `43651602940` поймал actor/autoclosure в AI review
initializer; `43652447120` — повторное имя request в LLM fallback. Исправления
`77209d28` / `4b3f7064` прошли указанный последний CI.

Последние коммиты добавляют самостоятельные Foundation-модели и тесты.
Остальная большая волна остаётся в рабочем дереве; она не входит в build 23.
Активной IPA-сборки или watcher на этой точке нет.

## Полученные первые срезы

Все 11 исходных ролей вернули source-handoff: Core/settings, appearance, chat,
privacy, AI/speech, tools, SDK, native plugin UI, TL, dependencies/build, parity.
Карта оригинала содержит 567 settings/state/templates, 30 modules, 925 SDK symbols.
После сверки незакрытые переносимые функции разнесены в следующую подволную.

## Текущее владение

| Роль | Session | Файлы / следующий результат |
|---|---|---|
| Inventory gaps — получено | `ses_e2443e129ffeJ4NxmpHRWiaEEO` | `remaining-ownership.*`: ещё 82 IDs; все назначены ниже/Chat/Extras |
| Core batch/CAS — получено, CI green | `ses_e243feabaffewbO5DkO2qNaCMs` | `applyPublic`/resetting/expected, 28 settings tests |
| Appearance phase 2 | `ses_e243f7abcffeGuUNpnkq2GkoQa` | Appearance policies/native views, навигация, styles, decorations |
| Chat phase 2 | `ses_e243f0df6ffeyOgNnZ6UAfr3px` | ChatFeatures/Policy/input/actions/links, `EnqueueMessage.swift`, privacy + explicit silent-send policy |
| Privacy fixes — получено | `ses_e243e9ec3ffeNQLS1mE6CHrtur` | Postbox boundary, bounds/cancel/expiry, central namespace, TL privacy metadata |
| AI phase 2 — получено | `ses_e243e30eeffevvi6PoeDOI6HKb` | Native boundary исправлен; shared compose/summary/auto/article/render hunks применены coordinator |
| Tools phase 2 | `ses_e243dc98dffe0Q86bXmQPlA0ju` | Backup journal/CAS/rollback, camera/tools helpers, subtitles/favourites |
| SDK/native fixture | `ses_e25088ca2ffeapc0yZ2vwlbKAh` | Python adapters/registry/tests и Swift+CPython SDK fixture |
| Plugin UI composition | `ses_e243ae7aeffeUQ5vuAwd50ZLES` | PluginUI, **ExteralessPluginRuntime.swift**, PluginSettingsController, Chat open-message/open-peer menu files |
| TL transformations | `ses_e243a7152ffeYsQQZoLZXmyT32` | TL helpers/schema/codec, new PluginTL* hooks, RPC/update mutation handoff |
| Build/resources — срез получен | `ses_e25088d28ffem4nSC3FcOP577B` | AdGuard exact pin + GPL, 203 imports/43 targets audit, iOS test labels; final staging после cohort |
| Native SDK services | `ses_e23dc0954ffeEMh9n0izZtjJbQ` | PluginServices, NativeService* helpers; queues/files/intents/logs/controllers |
| Retention | `ses_e23d7951effep2RWsy5h8oFA3t` | ExteralessRetention + RetentionFeatures; received-message edit/delete archive/media |
| Privacy extras | `ses_e23d72be2ffeRJmlhKY4LBsZxV` | Filtering/hidden accounts/panic; ExteralessPrivacyExtras |
| Host maintenance/gates | `ses_e25088ca0ffeSZG3hnR62kAl3y` | **PluginHost.swift / SubinterpreterManager.swift / PluginCallbackDispatcher.swift**, lifecycle tests |
| Player | `ses_e23c59fa3ffeQ9l6CFXD6gAPU7` | PlayerFeatures/new Player sources, native player/MediaManager/SharedMediaPlayer, lyrics/styles |
| Feed | `ses_e23c54cb8ffe3nH7QqgmL29dSQ` | ChatFeedPolicy/history + native feed screens; full media/receipts/pagination |
| Pills | `ses_e23c4f365ffein8sxkRXQqqmH1` | PillFeatures/providers + native pill screens/header handoff |
| App lifecycle — получено | `ses_e23c3fd88ffeMRAQjFJMkGEi7B` | AppDelegate/privacy/launcher и PeerInfo Ghost/phone применены; общие файлы возвращены coordinator |
| Stickers/emoji | `ses_e23aa4ae2ffeh4R3TtaQBhKaje` | P-stickers-emoji 21 IDs; Chat сохраняет shape/time, Tools — favorites |
| Dialogs/search/archive | `ses_e23a8d83effeF78mYrykWv5M0P` | P-dialog-navigation 16 IDs + два distinct sortByUnread |
| Local identity/premium presentation | `ses_e23a86f80ffep0m8LJJWGDJPxo` | P-local-identity 11 + P-local-premium 11 |
| Resolver/maps | `ses_e23a80a9cffeBJo6p90oWskp2w` | P-network-resolver 3 + P-maps 3 |
| Cloud/client API | `ses_e23a799e4ffexGANrzzE3WW4C9` | P-cloud-sync 3 + P-client-api 3 |
| UI frame harness | `ses_e23a4ef4effez9e9gzdD85RUdm` | NEW Tests/ExteralessHarness/**, его BUILD и client-ui-harness.yml — отдельное владение |

C owner-token role `ses_e25088d13ffeTRn8jKSxiC5l9R` возобновлена для исправления
подтверждённого P2 из независимого ревью: reentrant `__del__` при bulk handle clear
теряет C-ссылку. Отсоединение таблиц до DECREF/terminal gate и regression в работе.
Новый набор callback checks потребует обновить counts/fields runtime gate после
отчёта, не подменять старый 213-call artifact.

Последние 11 из 82 gaps: P-message-presentation 10 явно закреплены за Chat phase 2;
P-system-contacts 1 — за Privacy extras как exact Android AccountManager disposition.
R-runtime 16 manager/config IDs переданы UI+SDK; ExteraConfig 308 overload receipts — SDK.

После перезапуска сервера по запросу пользователя **20 незавершённых assignments
возобновлены в прежних sessions**; завершённые срезы повторно не запускались.

## Независимое ревью

| Роль | Session | Результат |
|---|---|---|
| C owner epoch | `ses_e23bd3fc4ffeaEV375EzI6saOZ` | `reviews/native-owner-token.md`: один воспроизведённый P2 bulk-clear leak; UAF/crash не подтверждены; owner-token новых дефектов не найдено |
| Settings/CAS/secret boundaries | `ses_e22059302ffeTTkt6sccLHsEbl` | read-only review готового Core-среза |
| AI original/native/provider parity | `ses_e22049f6dffeSiz0Jp8oE1BVLX` | read-only review AI после shared wiring |

Остальные независимые reviewers назначаются после стыковки соответствующих реализаций.
Результаты background задач приходят уведомлениями; не создавать polling.

## Coordinator: уже состыковано

- Shared native feature store/configuration до Account initialization; domain
  integrations создаются после выбора app-group file. Client bridge читает
  coherent redacted snapshot и использует атомарный запрет secret writes.
- Native owner UUID публикуется в HostState, затем C setter и SDK bind до load.
  BridgeServices проверяет epoch; native provider повторно сравнивает epoch при
  принятии асинхронного запроса. Terminal unload и bootstrap — отдельные admission состояния.
- Result-bearing callback dispatcher, per-owner callback/release FIFO; SDK cleanup
  идёт через `release_handles_json`, а не только C handle deletion. Mailbox gate и
  maintenance продолжаются у lifecycle-owner.
- `PluginBridgeExtension.exportedMethods`: side-effect-free discovery установленного
  provider, unknown остаётся unknown. UI/TL/services owners уведомлены о таблице.
- TL descriptor factory, TL provider composition и deep observation codecs
  подключены. Actual transformations добавляет TL-подволна.
- AI message/selected-text входы; appearance alternate icons, root contacts filter,
  chat-theme overrides и settings list styling; chat message actions и bot-command
  confirmation уже вставлены в общие файлы.
- Native effects получают `PluginNativeCallLease`; перед UI/send и после async
  подготовки повторно проверяют тот же epoch/grants. Очередь 256/plugin, 1024 total,
  32 MiB, tickets уникальны; unload не уменьшает счётчики новой lifetime.
- Legacy native runnable uses `onOwnedCallback(pluginId, ownerToken, ...) -> Bool`,
  reservation/rollback/completion привязаны к паре plugin+epoch. Runtime UI/SDK
  fixture/Host owners уведомлены о новом контракте; их части ещё собираются.
- Все три NativeServiceOpenHooks sites применены: external browser, incoming app
  URL и document preview; builtin plugin URL opener сохраняет effect lease/ticket
  до настоящего продолжения после before-handlers. UI-owner подключает provider.
- Центральный `Namespaces.CachedItemCollection.exteralessLocalState = 63` объявлен;
  privacy/retention/extras используют disjoint prefixes и удаляют только свои строки.
- Официальный PostboxImportCheck после AI boundary correction: exit 0 (отчёт AI owner).

## Следующие gate

1. Принять недостающие shared hunks, новые domain definitions/composition и schema
   registrations. Устранить коллизии keys/namespace/imports до запуска IPA.
2. Слить parity fragments с фактическими source/callsite/test evidence; проверить
   оставшийся gapset. Storage-only и platform adaptation не равны fake success.
3. Прогнать адресные suites и обновлённый macOS/iOS native SDK/runtime gate.
4. Независимые reviewers: original parity, SDK/C/lifecycle, native UI/main-thread,
   network/media/privacy и Bazel/resources. Исправить findings и перепроверить.
5. Полная unsigned IPA, проверка скачанного пакета; подпись/установка пользователем
   и визуальная приёмка по записанным кадрам. XcodeBuildMCP здесь отсутствует.
