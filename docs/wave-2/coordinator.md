# Coordinator — стыковка полной волны

Актуальная передача владения, проверенные commits/CI и дополнительные подволны:
[progress.md](progress.md). При конфликте со старой таблицей брать её.

## Уже реализовано

- `PluginBridgeExtension` / `CompositePluginBridgeExtension`, shared JSON envelope
  helpers; BridgeServices extensionProvider, native identity injection и общая
  validation/class policy до extension dispatch. Release providers вне NSLock.
- `PluginCallbackDispatcher`: sync generation capture, per-owner FIFO callback /
  release, admission result; owner-queue release в PluginHost. UI/TL providers
  могут принимать closures; `callback` возвращает Bool при admission/rejection.
- Per-plugin bulk settings: getSettings opaque JSON string, setSettings replace,
  updateSettings merge, clearSettings; atomic 1 MiB snapshot, validation до записи.
- Native client setting bridge (`Runtime.getClientSetting`/setClientSetting),
  permission settings, typed Core store и исключение native credential fields.
- `ExteralessClientRuntime`: composition root всех пяти native domains, Core
  definitions registration, shared root config, context lifecycle и reload.
- TelegramPluginServices.context(recordId:) для native UI/TL main-thread resolver.
- Immutable native owner epoch, bind C/SDK до load, per-owner result callback и
  SDK-aware release. Mailbox gate/maintenance переданы lifecycle implementer.
- Extension discovery через таблицу реально установленных `exportedMethods`.
- AI/appearance/chat shared menu и policy-врезки применены; TL provider и deep
  observation codecs подключены. AppDelegate/privacy/proxy hunks переданы integrator.
- Подготовлены meaningful tests extension identity/malformed replies/cleanup
  reentry/callback-release FIFO/stale owners и bulk atomicity/isolation/corruption.

## После получения агентов применить общие места

1. **Применено:** AppDelegate после app-group upgrades и до Account/Network initialization:
   `MainActor.assumeIsolated { ExteralessClientRuntime.shared.configure(rootPath: rootPath) }`.
2. **Применено:** existing context callback перед ExteralessPluginRuntime.update/clear:
   ClientRuntime.update(context:context.context) / clearContext().
3. **Применено:** PeerInfoSettingsItems: native ExteralessSettingsEntry factory row рядом с Plugins;
   использовать actual entry API core-settings-agent и уникальный item id.
4. ExteralessPluginRuntime после создания host: PluginCallbackDispatcher, composite
   [clientSettings, nativePluginUI, nativeTL] providers, их update/clearContext.
   Проверить actual constructors returned by providers и capability/permissions.
5. Network/common ChatController insertion hunks от privacy/chat/AI/UI/TL domains
   объединить в одном месте, не затереть уже работающие PluginHooks.
6. Сверить feature catalog declarations с actual native callsites, затем выполнить
   целевые suites, native probes и итоговую экономную unsigned IPA.

Baseline IPA на `68bb1adf` прошла 43635233046; теперь common client composition
стыкуется в новой волне. Типы domains и entry проверяются по implementer reports
перед объединённой компиляцией.
