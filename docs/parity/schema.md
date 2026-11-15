# Parity inventory contract

`python -m tools.compat.feature_inventory` produces `client-features.json`,
`sdk-surface.json`, `index.md` and the compatible `build/compat/features.json` /
`features-report.md`. `--check` performs a read-only regeneration comparison.
No Android build, JVM, plugin import, plugin execution, clone or network request
is part of inventory generation. Run the inventory with ordinary CPython.

## Stable identity and settings keys

- A feature `id` names its **original owning config + field**:
  `appearance.avatarCorners`, `chats.removeMessageTail`, `neko.sendOnlinePackets`,
  `nagram.showTextBold`, `general.botPrivacyEnabled`, `ai.saveHistory`.
- Before receipts, `ios.setting_key` is a proposed wave-2 `ClientSettings` key:
  `appearance.<originalField>`, `chats.<originalField>`,
  `privacy.<originalField>`, `ai.<originalField>`, `tools.<originalField>`.
  Short `enabled` fields are qualified by the owning subsystem. Any remaining
  collisions are explicit; do not register two distinct Android fields under one
  key without reviewing their semantics. An implementation fragment may override
  a proposed key with its actual typed definition key.
- The final source join uses the selected receipt key verbatim, including **null**
  for state, migrated/unused fields or explicit native-adapter gaps. Original
  config field names and Android `configName`/preference keys are never renamed.
- Source identifiers do not change if a feature moves between iOS groups.
  Do not use `getFoo` shim method names as client setting keys.
- `kind=state` distinguishes caches/migration state from user-facing controls.
  Counts of declarations, source references or SDK names are not feature parity.

Android file references are relative to
`third_party/exteraless-android/TMessagesProj/src/main/`. SHA-256 pins for retained
evidence are in `source_files`; the complete Java+Kotlin tree has a deterministic
digest. This is a plain-source snapshot: an upstream commit is **unknown**, not
guessed from a version label. Lines are 1-based. Defaults are declaration values;
conditional migrations must be considered before choosing an iOS initial value.
Sensitive and long defaults are not copied. No preference files, user values or
credentials are read.

`android-evidence.json` contains reviewed derived-collection edges and conditional
default notes. Every source anchor must still resolve before generation succeeds.
It is an input to the scanner, not a post-generation patch to the inventory.
In particular, the PillStack persisted strings feed materialized lists and the
preferred translation-language string feeds a separate Kotlin list property.
The moderation defaults' checked non-Config helper also feeds the class/static-
import index, preserving the actual Android effect for all five linked IDs.

## Evidence boundaries

`android.behavior=effect-callsite` means a non-settings/non-shim lexical consumer
was found. This is a **static candidate for behavior**, not dynamic reachability
proof. Separate categories retain UI setting definitions, config references,
backup/persistence, writes/metadata and compatibility shims. Reference totals
cover the scan; at most four references **per category per setting** are retained.
Comments and strings cannot make a setting live. Java and Kotlin block-comment
semantics are different and are handled separately. Java getters of Kotlin objects,
instance config receivers, static imports and getter-to-getter aliases are read.
Reflection/dynamic dispatch and arbitrary local dataflow need manual review.

`ui_definitions` independently indexes named rows, action rows, ConfigCell
definitions and control bindings. A row can refer to no ConfigItem (for example,
an import action or a stock Telegram control). Repeated bindings share a stable
ID, retain bounded `sites`, and record the full `site_count`. They are not added
to the setting count. Modules retain complete file lists, per-file pins, and
`public_method_bodies` with parameter types, return types, arities and lines.
That method-body index does not count constructors or interface-only declarations.

`compatibility_apis` records ExteraConfig API members separately. Its stable IDs
include parameter types, so same-arity overloads cannot collide. Mapped aliases
refer to real setting IDs. `compat-storage` persists a value for plugins but has
no mapped Android setting; it must not increase the functional setting count.

Every proposed native target is a pinned **integration candidate**, not an
implemented key read. `ios.existing_equivalent` records a stock capability and
its scope, not completion of the Exteraless toggle. Actual key reads belong in
`ios.implementation_callsites`. Default implementation/evidence is pending/empty.

## Independently supplied implementation evidence

Each owner can supply a separate JSON in their own scope; the coordinator merges
them with repeated `--parity path/to/fragment.json`. Example (replace the example
path and status with genuine evidence; this does not assert a passed test):

```json
{
  "features": [{
    "id": "chats.removeMessageTail",
    "ios": {
      "setting_key": "chats.removeMessageTail",
      "implementation_callsites": [{"path": "telegram-ios/path/to/consumer.swift", "line": 123}]
    },
    "implementation": {
      "status": "implemented",
      "ported": false,
      "evidence": [{"kind": "source", "path": "telegram-ios/path/to/consumer.swift", "line": 123}]
    }
  }]
}
```

Sections: `features` / `compatibility_apis` / SDK `symbols` are arrays with `id`;
`modules` / `legacy_trees` retain the old keyed-object shape. Fragments only
override implementation and iOS plan fields, never Android discoveries. Unknown
IDs and conflicting independent fragments fail. Removed entries with nonpending
evidence survive in `orphaned_parity` for review.

Statuses: `pending`, `in-progress`, `implemented`, `partial`, `verified`,
`stock-equivalent-verified`, `blocked`, `platform-prerequisite`, `unsupported`,
`compat-storage`. `ported=true` is derived only from the two verified statuses,
which require a `test`, `runtime`, `visual` or `review` evidence record with a
`path` or `url`. The generator preserves existing valid statuses/evidence on
regeneration. Both the tracked client file and an existing generated features
file are consulted; an older pending default cannot erase valid evidence.
Explicit fragments can downgrade a status. An Android key/type/default change
preserves the historical verified status/evidence, adds `source_review_required`,
and removes `ported` eligibility until a new explicit verification is supplied.
Old bare `ported=true` claims without evidence fail validation
instead of being silently reset or promoted. Visual claims still require the
recorded-frame evidence mandated by `telegram-ios/AGENTS.md`.

## Materialized source-only join

```text
python -m tools.compat.feature_inventory --source-join docs/parity/join-policy.json --receipts docs/wave-2 --docs-only
python -m tools.compat.feature_inventory --check-data
```

The first command reads each published `*-parity.json` once, applies explicit
owner precedence, regenerates the original inventory and targeted source anchors,
and writes only owned docs. It never runs the SDK manifest generator, Python SDK,
plugins, CI or native tests. `--check-data` reads only materialized JSON; it does
not require a live SDK manifest to remain frozen during another owner's work.

`--replay-source-join` together with `--source-join` reuses retained normalized
claims and their original receipt hashes when repairing the data adapter. It does
not sample moving owner receipts again. Source declaration/anchor snapshots are
still freshly derived and individually pinned. A later SDK receipt is a **new
cohort**, not permission to substitute a new hash into old claims.

Data fields:

- `source_claim`: primary owner, receipt path/hash, verbatim reported fields;
  `secondary_source_claims` preserves superseded/conflicting evidence. Chat is
  primary for the single selected-text ID; AI remains secondary.
- `implementation`: selected source status, with zero verified promotions. Prior
  independent verification is preserved; source-only authors cannot supply new
  `verified` claims through this route.
- `source_disposition`: explicit migrated, unused storage, Android mechanism,
  server/device prerequisite, portable-pending or scoped native adaptation, with
  owner reasons. Scanner candidate constraints are stored separately.
- `ios.implementation_callsites` / evidence: original line is `reported_line`;
  newly located `line` is present only for a unique symbol/anchor match. Ambiguous
  matches have bounded candidates. File-only pins make unresolved anchor
  granularity explicit; they neither prove a missing implementation nor runtime
  behavior. `origin=data-join-targeted-symbol` marks a supplemental checked source
  reference rather than an author-written line.
- `pill_types`: 15 separately retained original numeric IDs and source limits;
  normalized 20 Pill settings stay in the 567 feature set. Later integration
  reports overlay historical RTT/assembly notes without inventing measurements.
- `rollup` / `domain_contributions`: scoped partial module composition and exact
  outstanding authorship fields. All 30 module IDs and their full original method
  indexes remain present, regardless of rollup completeness.
- SDK `static_native_relation` retains lexical classifier output, while current
  `native_relation` distinguishes explicit published subsets from unreconciled
  symbols. A named class/helper cannot promote all 925 symbols.

The reconciliation stores exact ID partitions, API reasons, input metadata/hashes,
review layers, applied-source overlays, and read-time source pins. Review closures
are copied only from existing independent reports into their own layer; they do
not promote client/API parity. Final checks assert identity, author status/key
preservation, all 20/15 Pill joins, 567/30/925/308 counts and unchanged verification.

## Final source cohort (fac6cf26 request)

`final-source-join.json` binds the refreshed materialized inventories to the final
SDK input contract, current receipt hashes, scoped review closures and completed
data checks. `cohorts/93a1badc.json` locates the complete historical documents by
immutable Git commit/blob and raw SHA-256; earlier SDK counts, pins, receipt drift
and run IDs retain their original meaning. Historical planning/handoff documents
are not current completion tables.

- The SDK-owned canonical `sdk-config-input-v1` projection must remain unchanged
  when `client-features.json`'s derived body is regenerated. Run the existing
  `python -B -m tools.compat.sdk_config_manifest --check` after the join; do not
  rewrite its manifest or ten source-pinned input JSON files to make it pass.
- The final Config receipt has **276 implemented / 0 blocked / 32 unsupported**,
  **59 raw source pins**, **10 input receipts** and **308 exact overload IDs**.
  The separate aggregate's source-file count is not the SDK pin count.
- `chat-swipe` is the primary receipt for `etgbackup.ChatSwipeAction`; the older
  Tools claim remains secondary. The five applied portable policies use
  `portable-native-source-adaptation`, with actual Root/Cloud/consumer anchors.
  Author statuses remain verbatim; assets, native execution and visual limits
  are not erased by this disposition.
- A review identity includes its **report path**. In particular, AI `AF-03` and
  Avatar `AF-03` are different findings. `review_layers[].open_ids` records the
  published historical state; `supersedes` and the final cohort's
  `current_review_groups` supply the later scoped closure. The join itself does
  not issue review verdicts. Owner-reported fixes stay distinguishable from an
  independent final re-review.
- Mac component `43738810843 / 136c946f`, the last full Telegram IPA
  `43635233046 / 68bb1adf`, the requested full IPA `43740868881 / fac6cf26`, and
  the authored 36-label/410-method native plan are separate evidence identities.
  Component/standalone probe success cannot promote client/API `verified` or
  `ported`, or establish Telegram networking, UIKit or recorded-frame acceptance.

The existing scanner's Markdown renderer contains historical hard-coded CI and
review prose. The final Markdown reconciliation is an explicitly reviewed docs
projection; `--check-data` checks the materialized identity/status joins, and the
SDK `--check` checks the canonical consumed contract. Scanner/tool source is not
modified by this final reconciliation.

## Individual SDK and module source routes

The current projection is `individual-source-join.json`; the first fac6 join is
retained at Git `9bfce05f708fba472ca942bcfe355914847a347d`, with exact object/hash
locators in `cohorts/9bfce05f.json`. `final-source-join.json` and the older checksum
receipt describe that historical cohort, not the subsequently extended files.

```text
python -B -m tools.compat.feature_inventory --individual-only --docs-only
python -B -m tools.compat.feature_inventory --individual-only --docs-only --check
python -B -m tools.compat.feature_inventory --check-data
```

Ordinary `feature_inventory` generation also consumes the optional, explicit
`individual_manifests` list in `docs/parity/join-policy.json`. An alternate policy
can be supplied with `--individual-policy`. No directory glob chooses these maps.
Each descriptor has `kind`, `owner`, repository-relative `path`, raw `sha256`,
`expected_count`, and (for a module) `module_id`; optional route-count and captured
revision fields document the selected cohort. Missing policy/list is valid for
fixture projects without source or map files. A listed missing or changed map
requires an explicit policy/cohort update.

`--individual-only` reads materialized inventories and JSON maps. It does not
rescan moving production source, regenerate SDK Config or import SDK/plugins.
The ordinary path still rebuilds the lexical inventory, then preserves and
reapplies the individual layer. Older class-level source claims cannot overwrite
that layer. Both paths validate the same pure-data join before writing.

### Exact identity and attribution

- SDK: all **925** original IDs in four disjoint module partitions
  (**249 + 267 + 262 + 147**). Original `name`, `kind`, lines, parameters/defaults,
  return annotation and origin remain unchanged. SDK-copy/Android-original paths
  are accepted only for the corresponding declaration. Captured Original SDK
  file pins are compared to the scanner's original-file metadata.
- Module members: **14 General + 102 Settings + 666 Plugins**, each addressed by
  the structured `(file, name, ordered parameter_types, line)` tuple. A string
  display key cannot collapse same-arity overloads or repair unusual type tokens.
  The full **30-module / 2614-method** Original index remains intact.
- Settings additionally retains **55 actions + 47 named flows/row groups**.
  Plugins retains **666** exact `member_routes`, with explicit nullable native
  operation/provider, admission/lifecycle, evidence and unavailable reason.
- `individual_source` on each SDK symbol/module contains the raw owner receipt
  identity, original-declaration/index fingerprint, reported-payload fingerprint
  and verbatim `reported` route/member data. `individual_source_reconciliation`
  retains raw map size/hash, source boundary, captured pin fields and findings.
- SDK `native_relation.status` is `source-route-<disposition>`: `pure-sdk`,
  `native-adapter`, `plugin-contract`, `metadata`, `partial` or `unsupported`.
  These are source relationships, not native execution or `ported` statuses.
  New unverified implementation states are only partial/unsupported; existing
  independent verification is preserved without new promotions. The three
  module implementation states stay partial.
- Duplicate/unknown/omitted IDs, changed original signatures, malformed route
  shapes, missing partial limitations, invalid provider/null combinations and
  verification/native-execution promotion flags fail. Captured payload mutation
  also fails materialized-data validation. Exact repeated source references are
  allowed and never treated as duplicate record identities.

### Captured bytes and later source drift

The maps have mixed read boundaries. Core API pins Git `e16f3808`; other authors
record 9bf-era working-tree hashes. General supplies a d7 source boundary and
zero author raw-source pin fields. The captured boundaries are not silently
replaced by the latest worktree or by a component test's commit.

`individual-source-input-audit.json` is a separate read-time audit, not an input
to ordinary generation. It compares the **459** supplied pin fields per receipt,
retains each captured hash and records later current hashes separately. Matching
Git bytes recover old line bounds; no nearest-line/symbol guess is made. General's
**18** Git-derived d7 code pins are explicitly additional data-join evidence, not
new owner claims or execution evidence. Shared paths at different captured hashes
remain separate; later authorized source fixes do not invalidate an entire map.

Map findings remain owner-reported source findings until a separately supplied
follow-up overlay resolves them. Metadata declarations, native counterpart roles,
partial routes and missing providers never become implemented through a data
merge. Mac20 `43743252038/e16f3808` is independent component evidence and precedes
d7 scalar readers; it does not prove all 925 routes, native UI or the pending IPA.

All manifest reads are bounded (16 maps, 16 MiB/map, 12,000 rows, 2,048 pin fields,
64 steps/evidence entries per route); duplicate JSON object keys are rejected.
The final check report is `checks/individual-integrity.json`.
