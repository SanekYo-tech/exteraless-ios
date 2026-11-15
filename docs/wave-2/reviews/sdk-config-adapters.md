# SDK / Config / virtualjava — independent source review

2026-11-15. **Результат: 1 P1 и 8 P2; полная source-closure пока не подтверждается.**

Начальный HEAD — `aae32be6019297372c6b4ef0373d60775d05d851`, при заключительной проверке — `7d04a35a3612a2dc32dba6fb54744e38c07cabe9`. Ревью относится к applied working tree с raw SHA-256 ниже, а не к одному из этих коммитов. Во время чтения продолжалась стыковка Appearance/Tools. Реализация в этой сессии не изменялась.

Прочитаны `docs/wave-2-contract.md`, `sdk.md`, `sdk-wire.md`, `sdk-config-binding.md`, `sdk-tl-remediation.md`, `sdk-native-probe.md`, `sdk-runtime-hns-stitch.md`, прежнее `reviews/tl-network.md`, SDK/native handoffs и Telegram `AGENTS.md`/`CLAUDE.md`. Проверены SDK-стороны текущих Host/NativeServices контрактов. HNS-06, native composer/TL findings и закрытый C219 здесь повторно не выставляются.

Сокращения путей:

- `P/` — `python/exteraless_runtime/`; `V/` — `python/virtualjava/`.
- `U/` — `telegram-ios/submodules/TelegramUI/Sources/`.
- `C/` — `telegram-ios/submodules/TelegramCore/Sources/`.
- `H/` — `swift/PluginHost/Sources/PluginHost/`.
- `K/` — `swift/ExteralessCore/Sources/ExteralessCore/`.
- `A/` — `third_party/exteraless-android/TMessagesProj/src/main/`.

## P1

### SDK-01 — 44 global compatibility overloads не подключены к реальной регистрации Core

**Места:** `U/ExteralessClient/ExteralessClientRuntime.swift:54–61,80–83`; `U/ExteralessClient/ClientSettingsBridgeExtension.swift:72–98`; `P/_config.py:134–146`.

В `K/ExteraConfigCompatibility.swift:13–40` действительно объявлены 22 global definitions, и SDK направляет 44 overloads в `compat.exteraconfig.*`. Но единственный root `ClientSettings.shared.register(Self.definitions)` получает массив **без** `ExteraConfigCompatibility.definitions`. Provider выполняет validation, а не регистрацию отсутствующих definitions. Поиск actual Telegram registration sites не обнаружил другого подключения этой группы.

**Repro:** в обычном подготовленном приложении, на owner worker плагина с `settings`, вызвать `ExteraConfig.getTabCounter()` и `ExteraConfig.setTabCounter(False)`. Getter получает native null и выбрасывает `UnsupportedSurfaceError`; setter получает `Unknown client setting: compat.exteraconfig.tabCounter`. Даже наличие старого raw key в файле не заменяет регистрацию. Android `ExteraConfig.java:423–429` работает с общей preference `tabCounter`, default true.

**Impact:** вся группа из 44 заявленных implemented storage overloads недоступна через shipping composition; плагин может не загрузиться уже на чтении default. Подмена её per-plugin `getSetting` была бы другой семантикой и не является исправлением.

**Fix:** применить обе части уже подготовленного `docs/wave-2/sdk-config-binding-root.patch`: global registration и исключение compatibility state из generic feature UI. Это конкретный незавершённый coordinator handoff, а не ошибка самих 22 definitions. `git apply --check docs/wave-2/sdk-config-binding-root.patch` прошёл; patch на проверенном снимке ещё не применён.

**Test:** bounded native fixture должен использовать **root registration set**, затем настоящий `ClientSettingsBridgeExtension`: два plugin IDs видят одни global values/defaults, отдельные per-plugin values остаются раздельными; проверить read/write/reload всех 44 overloads. Нынешний `test_sdk_config_binding.py:40,65` сам задаёт отсутствующие в root definitions и поэтому пропускает этот разрыв.

## P2

### SDK-02 — Config generator не видит подключённые дочерние definitions; одной регенерации недостаточно

**Места:** `tools/compat/sdk_config_manifest.py:27–40,85–119,283–299`; `P/_config_manifest.py:194,470,659–660,853–854`.

Scanner читает закрытый набор файлов `HELPERS`. В нём нет `AppearanceAdditionalFeatures.swift`. Между тем actual `K/AppearanceFeatures.swift:238` уже добавляет `AppearanceAdditionalFeatures.definitions` и, в заключительном снимке, `settingsSectionDefinitions`; root регистрирует этот массив. Там реально объявлены `appearance.hideAllTab` и `appearance.useSystemIconShape` (`K/AppearanceAdditionalFeatures.swift:20–21,31–32`). Consumers существуют: `TelegramUI/Components/ChatList/ChatListFilterTabContainerNode/Sources/ChatListFilterTabContainerNode.swift:701–703` и `U/ExteralessClient/Appearance/ExteralessAppIconLogoView.swift:27–34`.

**Repro:** `sdk_config_manifest.build()` на текущем дереве всё ещё возвращает `key=None` для `neko.hideAllTab` и `icons.useSystemIconShape`; новый файл отсутствует даже в `SOURCES`. Поэтому `getHideAllChats()/setHideAllChats(boolean)` и `getUseSystemIconShape()/setUseSystemIconShape(boolean)` остаются blocked после regeneration, хотя их native fields уже подключены. Это проверено read-only.

**Impact:** SDK ошибочно сообщает отсутствие реальной настройки; receipt продолжает ссылаться на устаревшую причину «no native definition/consumer». Такой же blind spot появился у `ToolsFeatures.swift:66–69`, добавляющего четыре definitions из `ToolsNativeModePolicy.swift:6–14`, которого scanner также не читает.

**Fix:** учитывать фактическую цепочку регистрации и pin всех участвующих declarations; затем сверить original semantics и обновить SDK outputs. Нельзя считать любое найденное объявление зарегистрированным или превращать migration aliases в прямые getters только по совпадению `androidSymbols`.

**Test:** source/registration fixture с definition в реально подключённом дочернем массиве плюс public SDK read/write против native provider. Отдельный отрицательный случай — объявленный, но не подключённый массив. Зафиксировать точные четыре overload IDs выше; не ограничиваться проверкой общего числа 308.

### SDK-03 — Исправление false-cancel не распространено на controller operations и owner tasks

**Места:** `P/_controllers.py:23–31`; `P/_scheduling.py:60–69`; `P/_callbacks.py:24–28,66–71`.

`NativeOperation.cancel()` безусловно закрывает Python lease в `finally`, в том числе при native false/exception. Scheduler ещё до ответа удаляет task, вызывает такой же безусловный `dispose()` и возвращает `bool(selected)`, а не native cancellation result.

Это достижимый completion race: `U/ExteralessClient/PluginServices/PluginNativeServicesBridgeExtension.swift:436–441` сначала делает `operations.take`, затем отправляет terminal callback. `H/NativeServiceOperations.swift:107–110` после этого возвращает false. Аналогично `H/NativeServiceScheduler.swift:93–104` извлекает due task перед callback, а `:68–75` уже не может его отменить. Native terminal entitlement намеренно сохраняет принятую доставку (`H/NativeServiceCallback.swift:196–216`).

**Выполненный repro:** принять completion собственного `getUser`, задержать его до следующего owner entry, вернуть false из `nativeServiceCancel`, вызвать сохранённый wrapper. Получено:

```text
CONTROLLER_CANCEL false returned=False lease_open=False
callback belongs to a closed plugin generation
CONTROLLER_CANCEL throw -> тот же закрытый lease
SCHEDULER_CANCEL native=False SDK=True -> тот же отказ callback
```

**Impact:** теряется законный результат/ошибка; Runnable может не выполниться, хотя native cancellation проиграла. Это отдельные SDK endpoints, не повтор HNS-03 worker revocation и не переоткрытие исправленного `Requests.cancel`.

**Fix:** для live explicit cancel закрывать/удалять entry только после положительного validated cancellation; false/throw оставляют completion/FIFO release владельцами завершения. Unload cleanup имеет отдельную terminal semantics. Сохранить identity checks при удалении записей.

**Test:** добавить к controller/queue fixtures completion-before-cancel, false, malformed/throwing response, positive cancel и exact-once release. Проверять также фактический Bool, возвращаемый scheduler cancel. Контрольный `tlCancel=False` через нынешний `Requests` доставил root Vector и account ровно один раз.

### SDK-04 — Расширение native notifications ломает даже три уже поддержанных SDK события

**Места:** `P/_controllers.py:122–140`; native availability — `U/ExteralessClient/PluginServices/PluginNativeServicesBridgeExtension.swift:185–192,486–490`.

SDK принимает **только** весь список из IDs 25/46/137 и объявляет любой другой элемент ошибочным ответом provider. Actual `NativeServiceLivePublishers.swift:33–36` всегда добавляет как минимум `dialogsNeedReload` и playback events. Provider возвращает объединение, а не SDK-specific subset.

**Выполненный repro:** к валидному ответу 25/46/137 добавить настоящий `{id:3,name:"dialogsNeedReload"}`. И `center.supported()`, и `center.addObserver(delegate,25)` выбрасывают `RuntimeStateError("notificationSupported returned an unknown native event")` до native subscription.

**Impact:** на текущей app composition перестают регистрироваться даже `contactsDidLoad`, `mainUserInfoChanged`, `didUpdateConnectionState`. Положительные fixtures скрывают несовместимость: `test_sdk_adapter_wave2.py:47–48` сообщает ровно три старых события; `test_native_sdk_hns_fixture.py:50` — только 25.

**Fix:** синхронизировать SDK event registry с реальным native contract; корректно сформированные дополнительные availability rows должны давать поддержанный subset, а не ломать существующие subscriptions. Для новых событий отдельно реализовать их actual argument shapes: текущая проверка `args == []` на `:149` не подходит всем новым событиям.

**Test:** собственный fixture с полным actual availability table; старые три подписки продолжают работать, неизвестный корректный ID не ломает их, неверный name для известного ID отклоняется, native отсутствие конкретного publisher остаётся явным отказом.

### SDK-05 — setPinnedPlugins продолжает отдельные записи после отзыва settings/owner

**Места:** `U/Exteraless/ExteralessPluginRuntime.swift:586–597,804–812`; `U/ExteralessClient/PluginUI/PluginConfigBridgeExtension.swift:37–44`; `K/ExteraConfigCompatibility.swift:174–179`.

`isCurrent()` проверяется один раз перед switch. `.pinned(wanted)` затем выполняет отдельный durable `updateManagerPreference` для каждого plugin ID, с await между ними. После await нет повторной проверки. Отзыв удаляет pending queue entries, но не executing entry; это правильно для уже начатого self-disable maintenance, однако не охраняет последующие pin writes.

**Source repro:** установлены `aa` и `bb`, оба unpinned. Вызвать `setPinnedPlugins({"aa","bb"})`; удержать завершение первой detached записи. Отозвать у caller `settings` через `setPermissions` (`:418–421`) либо unload caller; отпустить первую запись. Цикл без guard запускает новую запись `bb`. В отличие от первой уже допущенной atomic write, вторая ещё не была начата в момент revocation.

**Impact:** глобальные manager preferences продолжают изменяться новым effect после истечения captured authority. Проверки на admission и первом main entry этот async промежуток не закрывают.

**Fix:** повторять lock-only authority check перед каждой независимой записью или сделать один native atomic pinned-set commit с определённой точкой admission. Сохранить возможность завершить уже начатую self-disable maintenance transaction.

**Test:** bounded two-ID fixture с gate после первого commit; revoke grant и отдельно owner, затем разрешить continuation — второй write не выполняется. Контроль без revocation обновляет оба ID. Это source finding; Swift execution этого сценария здесь не выполнялось. Существующие Core queue tests проверяют FIFO/retirement через injected apply, а не этот Runtime loop.

### SDK-06 — Java byte[] сериализуется в TL как vector

**Места:** `V/arrays.py:15–25`; `V/finder.py:114–122,137–146`; `P/_tl.py:80–100`.

`jarray(jbyte)` — list subclass без wire-specific byte codec. `to_wire` распознаёт только Python `bytes`, после чего любой JavaArray проходит list branch. Тот же generic C list branch не превращает его в bytes (`python/bridge/_exteraless_bridge.c:1531–1542`).

**Выполненный repro:** `messages.getBotCallbackAnswer(peer=inputPeerSelf,msg_id=7,data=jarray(jbyte)([-1,0]))` даёт `"data":[-1,0]`. Контроль `data=b"\xff\x00"` даёт `"data":{"__bytes__":"/wA="}`. Native codec обязан отвергнуть первый вариант: `C/ExteralessRuntime/TLCodec.swift:521–522` требует bytes marker. Android TL byte[] — действительная data surface, например `A/java/org/telegram/tgnet/tl/TL_keyboard.java:274–291`.

**Impact:** корректный оригинальный SDK код с typed Java byte array не может отправить bytes-bearing request/field, несмотря на объявленную поддержку arrays/TL. Это Python adapter defect; native strict bytes validation верна.

**Fix/test:** сохранять явный primitive component identity и кодировать byte[] как исходные 8-bit bytes с signed Java byte conversion. Int[]/Long[] остаются arrays. Проверить пустой byte[], -128/-1/0/127, nested byte[] field, plain bytes control и реальную native codec normalization в bounded child.

### SDK-07 — Каждый jarray(T) создаёт другую class identity

**Места:** `V/finder.py:114–122,137–146`; `V/arrays.py:4–37`.

Array factory не кэшируется; primitive converters также заново создаются при обращении к `java.jint` и аналогам. Поэтому class identity не определяется component type.

**Выполненный repro:** после `a = jarray(jint)([1,2])` выражение `isinstance(a,jarray(jint))` ложно; `cast(jarray(jint),a)` выбрасывает TypeError. Это даже при одном и том же сохранённом `jint` converter. Обычный повторный `jclass` имеет cache; данное исключение относится именно к arrays.

**Impact:** typed casts, overload/type checks и helpers, независимо получающие один array class, не принимают корректный array. Никакого unavailable operation при создании такого класса SDK не сообщает.

**Fix/test:** интерпретатор-локальный cache по каноническому Java component descriptor, со стабильными primitive identities; проверить повторные imports, nested arrays, cast null, same-component success и different-component rejection. Не объединять int[] с long[] по общему Python storage class.

### SDK-08 — Boxed Java equality теряет тип числа и значение Boolean

**Места:** `P/_java_types.py:16–23,239–244,295–318`.

Integer/Long наследуют Python integer equality, а Boolean — identity equality `Object`. HashMap использует эти Python keys напрямую.

**Выполненные repro:** `HashMap.put(Integer(1),"integer"); put(Long(1),"long")` оставляет **одну** entry вместо двух; `Boolean(True).equals(Boolean(True))` возвращает false. У Java `Integer.equals(Long)` false, у двух Boolean одного значения — true. Это сравнение конкретных Java value classes, не требование эмулировать весь JVM.

**Impact:** смешанные Java-key maps/sets молча перезаписывают разные entries; Boolean value comparisons/deduplication дают другой результат. Простая проверка Int64 roundtrip не обнаруживает эту потерю semantics.

**Fix/test:** implement type-aware boxed `equals`/hash/key semantics, сохраняя явное unboxing для native scalars. Fixtures: distinct Integer/Long keys, equal independent Boolean keys, null key/value, overwrite return, remove, и Int64 >2^53 через реальный C scalar transport. Python `_codec` контроль `[Long(9007199254740993),True,None]` сохранил значения; C source также различает PyBool и PyLong — этот finding не приписывается C219.

### SDK-09 — HashMap.keySet/entrySet выдают detached lists вместо backed views

**Места:** `P/_java_types.py:239–252`, особенно `:249–250`.

**Выполненный repro:** `m=HashMap({"x":1}); keys=m.keySet(); keys.clear()` успешно возвращает None, но `m.size()==1`. В Java `Map.keySet().clear()` очищает map. Полученный ранее `keySet` также не видит последующий `put`; `entrySet().clear()` имеет ту же проблему. `Entry.setValue` при этом действительно меняет исходную map, поэтому получаются противоречивые частично-backed semantics.

**Impact:** оригинальный код удаления/синхронизации через views сообщает успех, оставляя entries. Это не честно отклонённый неперенесённый метод.

**Fix/test:** backed collection views с Java remove/clear/iteration contracts либо явный unsupported для ещё не реализованной операции. Проверить изменения map после получения view, удаления через view, `Entry.setValue` и запрет `add` новых keys через keySet.

## Проверенные closure и границы

| Область | Независимый результат |
|---|---|
| Original public SDK | Все **36** `python/sdk/**/*.py` byte-identical `A/python/**/*.py`; дополнительных Python SDK файлов нет. `docs/parity/sdk-surface.json` содержит **925** public symbols. Это inventory, не 925 behavioral passes; его adapter pins относятся к более раннему снимку. |
| Config exact inventory | Frozen receipt: **260 implemented / 16 blocked / 32 unsupported = 308 unique exact IDs**, partition **220 mapped / 44 storage / 44 utility**. Read-only merger сохранил тот же ID set. Эти статусы не являются доказательством app registration или полной переносимости 32 utilities. |
| Global storage/defaults/types | 22 definitions совпадают с original defaults/enum ordinals; generator проверяет Java/Kotlin pins. Strict reads не подставляют Android default. Metadata спрашивает текущую native definition; bool/int/long/float/String и nullable String setters проверяются явно. Глобальная registration failure — SDK-01. |
| Atomic snow / public writes | `P/_config.py:167–173,252–255` делает один opaque JSON `setClientSettings`; provider `:47–58` → `ExteraConfigCompatibility.applyPublicJSON:73–78` → один public transaction. Secret/learned-alias checks и native-editor exclusions сохранены. Per-plugin merge/replace/reset идут в отдельные opaque bulk services (`P/_settings.py:12–34,58–63`). |
| 13 manager overloads | 11 real field bindings + 2 explicit ART exclusions. Состояние читается из actual `PluginManagerPreferences`, setter возвращает None после `{accepted:true,operationId}`, не обещает delivery. Queue учитывает executing credit, 128 total/32 owner, pending old owners отзываются. Self-disable не ждёт C синхронно: Runtime asynchronously ждёт root operations, затем использует nonterminal maintenance. Checked Host resume восстанавливает enabled flags, не очищает permission store. Native execution ещё требуется; отдельный pin-loop grant gap — SDK-05. |
| TLN06 | `P/_tl.py:347–360` сохраняет lease на false/malformed/throw, закрывает лишь на true; owner/native-ticket и identity-checked pending removal есть. Собственный false-cancel control доставил callback однажды. SDK-03 относится к другим endpoint adapters. |
| TLN07 | `P/_tl.py:519–585`: rich/reply/scheduled → `sendMedia(kind:text)`, edits → `editMedia(kind:text)`; no raw getPeer/tlRequest detour. Собственный messages.send-only recorder проверил entities, namespace-bearing reply, notify/searchLinks inversions, schedule/thread, omission против empty caption/false spoiler; все handles очищены. Plain send оставлен на native legacy service; native ancestry/CMC verdict здесь не дублируется. |
| TLN08 | Собственный probe проверил false→true→false masks, flags2, сохранение unknown bits и missing/present shared-bit value companions. Native strict normalization не заменялась Python-проверкой. |
| TLN11 / identity | Root declared vectors имеют стабильное `.objects`, primitive Int/Long wrappers, read-only context и wire-array serialization; nested vectors остаются ArrayList. `Vector.java:7–14,53–101` сверено. Найденную ранее пару `KeyboardButtonRow`/private `TL_keyboardInlineButtonRow_layer228` нельзя автоматически объявлять одной original Java class: в `TL_keyboard.java:645,749` это разные declarations с одинаковым constructor ID. Повторное exact class lookup кэшируется; отдельная доказанная identity ошибка — SDK-07. |
| SDK UI callbacks/settings | Presentation wrappers distinct; admission failure и native FIFO release разведены; stable update callbacks/refresh rollback читаются в `P/_ui.py:25–66,370–388,498–534`. Собственный `HandlerError` прошёл через `invoke_handle_json` с исходной exception identity, cleanup не замаскировал его. SDK `safe_call` остаётся намеренно nonthrowing, как original. Slider negative/fractional/non-divisible ranges проверены на actual `ui.settings.Slider`; native range formulas сопоставлены с `PluginSettingsModel.swift:47–68`. UIKit/frame verdict отсутствует. |
| Owner/account/thread | `Platform.check_worker` отверг отдельный bounded background thread. `_settings_account` сохраняет None/old arity и slot 41, отвергает Bool/negative/non-Int32; callback scope восстанавливается. Runtime HNS update/click передают captured owner/account/lock-only predicate. Module helpers по original default используют selected account; `AccountClient` — explicit → hook → selected. Notification delegate intentionally не получает implicit hook scope. |
| Explicit registry/backend | Registry содержит exact classes/factories; Config unknown fields не создают getters. `configure:74–79` требует actual C BridgeBackend; Runtime metadata lookup live (`V/proxy.py:17–29`). `_Universal` остаётся в desktop MockBackend, production bootstrap на него не переключается. Own probes используют явно объявленные unit recorders, не native-pass impersonation. |
| Provided dependencies | `_dependencies.py` допускает только полный wave-1 **8** либо wave-2 **12** inventory, валидирует `.dist-info`, extras/versions; runtime pip/download endpoints отвергаются. Lock сейчас содержит 12, repository-local `python/vendor/exteraless-dependencies.json` — **8**. Поэтому 12 packages нельзя объявить выполненным bundle/import pass этого review. debugpy projection не доказывает listen/attach; lxml/Pillow не входят в этот provided Python набор. Native dependency packaging — отдельный gate. |

## Реальный drift после Config freeze

- `py -3.12 -X utf8 -B -m tools.compat.sdk_config_manifest --check`, лимит 20 s: **exit 1**, `SDK Config generated output is stale: python\exteraless_runtime\_config_manifest.py`.
- Read-only `build()` даёт **262/14/32**; единственные promotion среди 308 IDs — `getUploadSpeedBoost()` и `setUploadSpeedBoost(boolean)` к новому `tools.uploadBoost`. Accepted outputs не перезаписывались. Этот candidate также имеет scanner blind spot SDK-02.
- Из frozen `SOURCES` изменились `appearance-parity.json`, `chat-parity.json`, `tools-parity.json`, `AppearanceFeatures.swift`, `ToolsFeatures.swift`, `ExteralessPluginRuntime.swift`. Во время review дополнительно подключились Appearance settings-section definitions и Tools mode definitions; заключительные hashes ниже относятся к ним.
- HNS stitch receipt называет Runtime `cac276516c768a12660780810fb4efa0657178194f86db88c4fa196c5e2f07eb`; actual reviewed Runtime — **`0760f770…`**. Более старый Config pin — `0f70d82e…`. Сравнения полного файла на equality здесь нет: видны последующие shared changes, в том числе Tools toggle trace на `:323–327`. Current HNS account forwarding и Config composition прочитаны непосредственно.
- В regeneration candidate direct fields меняются шире, чем 308 overload statuses. В частности, `NaConfig.disableCrashlyticsCollection` превращается в direct binding `tools.crashReports`, хотя original/native handoff описывает **migration true→false, false→no enable**, не положительный live alias (`tools-owner-completion.md:28`). Current frozen binding ещё `None`; это риск **candidate reconciliation**, не уже исполненный production setter. Аналогично `rearVideoMessages` Bool нельзя подключить напрямую к enum-facing field с Ask=2; type mismatch сейчас честно не допускает такое связывание.

## Выполненные проверки и оставшийся native gate

Исполнялись только небольшие собственные in-memory Python fixtures, без plugin corpus, live accounts/network/CI и без изменений implementation files:

1. CPython **3.12.10**, внешний лимит 20 s: production controller/scheduler cancel, notification availability, positive TL cancel/root Vector, typed byte-array wire, array cast identity, HashMap keys/views, scalar JSON. Подтверждены SDK-03/04/06/07/08/09; в конце zero fixture handles/leases.
2. CPython **3.14.8**, лимит 20 s, единственный thread с `join(2)`: original HandlerError identity, owner-worker denial, nullable/Bool settings account checks, flags/shared companions, original Slider normalization и boxed Boolean comparison. Контроли прошли. Первый scaffold запуск остановился из-за отсутствующего `xt_resolve_handle` у recorder; добавлен только in-memory recorder method, production код не менялся.
3. CPython **3.12.10**, лимит 20 s: production `_tl.install` и high-level reply/rich/schedule/edit paths с единственным `messages.send`; проверены четыре точных native DTO и cleanup. Первый scaffold запуск потребовал установить unit `base_plugin.PluginServices`, как это делает bootstrap; повторный прошёл.
4. Read-only source/ID/pin comparison и `--check`, указанные выше; pending root patch apply-check прошёл. Native registration и pin-loop сценарии — source proofs, не исполнение Swift.

Owner receipt **42 behavioral cases passed на 3.12/3.14 + отдельный failing drift check** прочитан в `docs/wave-2/tests/sdk-python-checks.json`; все 42 заново не запускались и не выдаются за независимое покрытие 925 symbols.

**Swift/swiftc на этом Windows host отсутствуют.** Текущий `tools/runtime/check_swift_plugin_embedding.py` действительно требует три независимых 30-second children и все три reports/markers. Этот gate **не запускался**. Source closure TLN06/07/08/11 не равна real C/CPython/Swift pass; даже successful Foundation DTO children не доказывают UIKit frames, production outgoing enqueue/state или Telegram delivery. Для Mac нужна заново согласованная source fingerprint и sealed dependency bundle. Старые green baselines, включая C219, не покрывают новые SDK findings.

## Loginless reproducer для cancellation/availability

Из repo root: передать следующий код в `py -3.12 -X utf8 -B -`, внешний timeout **20 s**. Recorder моделирует уже выигравший native completion; native достижимость указана в SDK-03. Загружаются production Python modules, внешний plugin не исполняется. Здесь callbacks вызываются непосредственно, поэтому это не C/Swift execution proof.

```python
import contextlib, sys
from types import SimpleNamespace
sys.path[:0] = ["python", "python/sdk"]
import client_utils as client
from exteraless_runtime._callbacks import CallbackLeases
from exteraless_runtime._controllers import install as install_controllers
from exteraless_runtime._scheduling import Scheduler

class Recorder:
    def __init__(self):
        self.plugin_id, self.owner_token = "ownSdkReview", "review-epoch"
        self.handles, self.waiting, self.serial = {}, {}, 0
        self.loader = SimpleNamespace(
            plugin_context=lambda _: contextlib.nullcontext(),
            client_utils=client, require_permission=lambda *a, **kw: None)
        self.bridge = SimpleNamespace(
            xt_register_handle=self.register,
            xt_release_handle=lambda h: self.handles.pop(h, None),
            xt_call_host=lambda r: self.call(r["member"], *r["args"]))
        self.callbacks = CallbackLeases(self)
        self.callbacks.begin()
    def check_worker(self): pass
    def register(self, fn):
        self.serial += 1
        self.handles[self.serial] = fn
        return self.serial
    def supported(self, member): return member == "nativeGetUser"
    def call(self, member, *args):
        if member in ("nativeGetUser", "postToOwner"):
            ident = "ticket-" + str(self.serial)
            self.waiting[ident] = args[0] if member == "postToOwner" else args[1]
            return {"id": ident}
        if member in ("nativeServiceCancel", "cancelOwnerTask"): return False
        if member == "notificationSupported":
            return [{"id": 3, "name": "dialogsNeedReload"},
                    {"id": 25, "name": "contactsDidLoad"}]
        raise AssertionError(member)

p = Recorder()
client.get_selected_account = lambda: 2
install_controllers(p, client)
operation = client.get_messages_controller(2).getUser(101, lambda *a: None)
callback = p.waiting.pop(operation.id)
assert operation.cancel() is False
assert not operation.lease.open
try:
    callback({"id": 101}, None)
except RuntimeError as error:
    assert "closed plugin generation" in str(error)
else:
    raise AssertionError("Expected the current SDK-03 failure")
p.callbacks.release_handles(list(p.handles))
scheduler = Scheduler(p)
task = scheduler.post(lambda: None, "PLUGINS_QUEUE")
assert scheduler.cancel(task) is True  # Native returned False.
p.callbacks.release_handles(list(p.handles))
try:
    client.get_notification_center(2).addObserver(client.NotificationCenterDelegate(), 25)
except RuntimeError as error:
    assert "unknown native event" in str(error)
else:
    raise AssertionError("Expected the current SDK-04 failure")
assert not p.handles and not p.callbacks.leases
print("SDK-03/04 reproduced; fixture handles/leases = 0")
```

## Source pins

Raw SHA-256 без newline normalization. Python adapter pins оставались стабильными между основным чтением и заключительной сверкой. Для original 36 SDK files общий digest — `9eff1a8c957fd2692f821b2ae787d5b5ffbe358f69de7ac9b4023736e8571ec7`: сортировка по SDK-relative POSIX path, конкатенация `path + NUL + raw_sha256_hex + LF`, затем SHA-256 UTF-8. Этот digest одинаков для `python/sdk` и `A/python`.

```text
02526f84911a0dfdbcb9927885f947730cbf4671e37f79ea28d44a656a3f16c6  P/__init__.py
70497a280c5ebc081e662fc72c656bb907df721981c19e2929f7c815e638c481  P/_callbacks.py
7446c4fb12e69de694f2289ad8943654abaec17a8f792c2446e8b8811d04caf9  P/_config.py
43b5b472c121bfb719e0e2bbd9fc86c1e095ca2356e81eaaf53ec62f9ca9b808  P/_config_manifest.py
32861e5d2cae7f881f00ecec8c9a67cad0271a6e95ef60c4ff883e5dd99990b4  P/_controllers.py
12e0e8df111c43f6ee553f7b668c92cbaa5efc2eceb65589a52dd5b661635dc2  P/_java_types.py
f5cb8bbadebdb8a66494a371c9b5cbe05edc47242a95e4e16e03c2ed003cd7df  P/_scheduling.py
a237621adb7d10cf38a2887983a93d9b95ac3175487d9d33be78f25c3e690f25  P/_tl.py
ddb40e7b43bea182b6895f83a038aacd0233d378eff359899369d829047cf853  P/_ui.py
10236d669c076071280186165d7a22ad68a8d1ac03564dc61b3fd4721316db1a  P/_platform.py
30669ce63a2d5707a0ef34b89a0b93a7e96517f103cb40a31a6d1f5acfa61a16  P/_dependencies.py
a9c6b19357d0a637dd6f6c641198cd37552f317ac1202722291fde3a313fe6fb  P/_codec.py
e15f5fa6d292f383031139aa1b03f1d095d29aa557233f697897ba99c7ac122c  P/_registrations.py
9421584fbc940ffb54f191d6b9726de36b53d6c037b6a71278ea49bfa20077a2  P/_settings.py
b52cfc69b916a78ced37a7e9cb5fec489d28229c83caf80cb9b3359a6027c996  P/_audit_paths.py
2e760eb79adb6420cc30ca807831f8f318114a559fd3538de5f3d9aa24da577a  V/arrays.py
7e91c52c8e654dc0202884343dc9e5357e753581868d50bf9c2d31be160250bb  V/finder.py
dbc949b9059a028ed395aaff1388afcae826a519d0eda9126a6838404059c2f2  V/proxy.py
7ad5d5125e4dd231b07fe3145402e1113aab639fa57af2e22d10e5aa033e69b8  V/registry.py
8b3dd4a89782d9844407708dec259f1c759d2ce6da93b92b4a2ba301951b2dc9  tools/compat/sdk_config_manifest.py
5cf5fbe589978ac0bfbb75aeb206318f34b6c7ef6d3c11532a888608baa26d15  docs/wave-2/sdk-config-parity.json
3ef530e3696753f6a0ab2b579d62249eedbd23596ecfdef92318ad460269049b  docs/parity/sdk-surface.json
e02140d484cabcafbaa0545a017c5be9f6904c74ab0a9e74c3848af8b7ecd221  python/runtime/tl-schema.json
f9a94d4ed8cbaa7fae9e23f7b232313fa838a89c5407b60a603cebcea277f92a  python/bridge/_exteraless_bridge.c
35eee798ab988f79f6a2d77e512b8fedda06c1d2f3f41f4cc65e345b8e4ffefe  K/ExteraConfigCompatibility.swift
ec7b61074fae6c89f54e7697f60d7780cd3a1f8e9c658ed78ad6a60155a99225  K/AppearanceFeatures.swift
e779cc5e1d74a533a7272a6023038db67966fa17af1b481c0ce03b8bd5ef303b  K/AppearanceAdditionalFeatures.swift
b5cca254c1770cfc6504af9db541a2bd4b6f4c87dfe98531321765be6fd4f7de  K/ToolsFeatures.swift
950973b1a855e6dcfb27a5a162e9696b0e8429e925b8481306caa0e10ed3c3b8  K/ToolsNativeModePolicy.swift
e7a2637838e675d4793f9647aa1419c28ff7f65adf54e713eccf1ff074baa89d  U/ExteralessClient/ExteralessClientRuntime.swift
6eb4ced5c24af192e3b099337563314b9e6ff444a36d565d305748a597218043  U/ExteralessClient/ExteralessSettingsController.swift
e0600d7492f6e9a478341235ff451147fc0e41fe2908d0925af50e9d14897717  U/ExteralessClient/ClientSettingsBridgeExtension.swift
3382f26116bcc5f49c4c32be648654a86d8c3372da6fc5ab0816cbb60db17769  U/ExteralessClient/PluginUI/PluginConfigBridgeExtension.swift
2d327e7f4059580afb987d1ba3b8315e8565f7754bba9d9e81baa45e13d785e0  U/ExteralessClient/PluginUI/PluginManagerPreferences.swift
0760f7701e963c1ea052f6dbe6d5b3b7924293b323bfba273922d3d3ad63af65  U/Exteraless/ExteralessPluginRuntime.swift
2c6330e389e99b8de4bc9da73e2260e14bb80be6e5509870f0c60b78d8b838b6  U/ExteralessClient/PluginServices/PluginNativeServicesBridgeExtension.swift
e1edc12cbbfe2bcf817cc8a746982da05006743c5235432c2d9b29b08acc1222  U/ExteralessClient/PluginServices/NativeServiceLivePublishers.swift
ef7e30b5c6f4fa7348760613918675d4f0976493802c7913aa4689ce7de93e5e  H/NativeServiceCallback.swift
695ff2cef7af8dcad96b28ff329574f0d09764676b5a94189b30d996a8ec3369  H/NativeServiceOperations.swift
c64fda685439f416513b94c23b05bf64883cc986ba99d1dceddaa02e016ee83f  H/NativeServiceScheduler.swift
c22611ed58f5594e27e8087da14f272eabed38e5c5b8306049d224af9c710863  C/ExteralessRuntime/TLCodec.swift
384de71c6f5870facf969ad2ad915a1ed40f34a2da405e01eda72542482c0239  A/java/com/exteragram/messenger/ExteraConfig.java
65161f6ed60e2439f6c783b51aa3e31ad30f13d92743bde384ee1e6036c5dbd6  A/java/tw/nekomimi/nekogram/config/ConfigItem.java
b587a58fa7525d062d1602e3289bed35d3d41e8b50e23116ca7d72b9fa99d824  A/java/org/telegram/tgnet/Vector.java
a026f2b766ea4ca29c9abee0a4010773d4c7f38b848939b17eeee1068388b6bc  A/java/org/telegram/tgnet/tl/TL_keyboard.java
d9c956a1d20fb9b192f5be3bb4aee3460a456eeeec7efbbbc9a8b8f550524b9f  tools/runtime/check_swift_plugin_embedding.py
3fa1fca4d82e74324bb50f214d3572d5f8ef522d1d2eb275f92c398a5c95320a  tools/compat/tests/test_sdk_adapter_wave2.py
1505c6e2db8ea4a6cbb41b94076257c52d2eb3092bc9608c6f1c5cec05d8ac44  tools/compat/tests/test_sdk_tl_remediation.py
d65046859fa39851864ccf43c9d87af60cf2cadf300f5f2bc249c3b9d761a75a  tools/compat/tests/test_sdk_config_binding.py
db0c5912bb32aae2f760fce4dc49c3914536d2fb277f5e9b5d56cef9a76112e2  docs/wave-2/tests/sdk-python-checks.json
```
