# Exact SDK symbol source routes

This follow-up supplies individual source dispositions for the immutable 925-ID
SDK inventory. It is not an execution/visual promotion. Original declarations and
parameters remain in `docs/parity/sdk-surface.json`; author maps cite them by ID.

Each group supplies JSON with `schema_version: 1`, `modules`, `source_boundary`,
`source_sha256`, `symbols`, and `findings`. Each symbol must have:

- `id`, matching exactly one original inventory symbol;
- `disposition`: `pure-sdk`, `native-adapter`, `plugin-contract`, `metadata`,
  `unsupported`, or `partial`;
- `original`: `{path, line, symbol}`;
- `route`: ordered `{path, symbol, role, line?}` references to the actual body,
  adapter/registration and provider as applicable;
- `contract`: a specific explanation of what this exact symbol does;
- `limitations`: an array, including platform/provider limitations when present;
- `evidence`: exact named source/test/report references;
- `ported: false`, `verified: false`, `native_execution_claimed: false`.

Pure helpers, metadata and plugin override contracts cite their actual body or
declaration. Native-facing symbols require the concrete terminal adapter/provider;
importability or an unrelated generic helper is not sufficient. An unresolved
provider is `partial` with a concrete missing operation, not an invented mapping.
Existing named test receipts may be cited with their original scope and commit.

Partition:

| Group | Modules | Symbols |
|---|---|---:|
| `core-api` | android_utils, base_plugin, client_utils, hook_utils, intents | 249 |
| `utilities` | file_utils, markdown_utils, plugin_settings, pip_controller, dev_server, all extera_utils modules | 267 |
| `elyx` | elyx_runtime and all its submodules | 262 |
| `ui` | ui.settings, ui.alert, ui.bulletin | 147 |

The coordinator joins by exact ID, rejecting overlap, omissions, unknown IDs and
missing source anchors. Production code and existing source receipts remain
separate inputs. Findings go to implementation owners before any compatibility
claim is advanced.
