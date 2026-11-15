# SDK Pill adapter — wire v1

`_pill_types.py` and `_pills.py` consume the published `pills-wire.md` and actual
`PluginPillBridgeExtension`. The original Java/Kotlin classes are registered under
app.exteraless.pillstack names; existing exteraGram aliases resolve to them.

## Implemented

- PillInfo's fields and same-named accessors; PillCreator's exact two-argument
  create(context, resourcesProvider); all 15 source PillType constants.
- PillRegistry.register/unregister/getPillInfo/createPill/activatePill for owned
  registrations. Admission returns nativeId/registrationId onto the actual PillInfo.
  Duplicate registration fails explicitly; unregister precedes replacement.
- Five unique C callback wrappers per registration: start/update/tap/longPress/stop.
  Only longPress returns a Bool. Stop cleanup exceptions are logged locally and
  return None. Ordinary stop does not release the registration's wrappers.
- Up to eight concurrent native selection contexts, with a separate BasePill per
  selection. Context includes the actual account slot, decimal accountRecordId,
  generation and selection. Old setters retain their old selection and fail after
  stop/account replacement/retirement instead of updating a newer view.
- Portable BasePill.setContent, loading and actual timestamp helpers. Content uses
  the native value/detail/source/phase/updatedAtMs/progress/isHighlighted fields.
  Missing measurements stay missing. Android View geometry is explicitly unsupported.
- Layout ArrayList drafts retain identity and unsaved edits. Own native IDs translate
  using returned mappings; opaque native IDs retain a tagged integer identity so
  an equal-numbered Android alias cannot redirect them. Python allocates no native IDs.
- getActivePills/getHiddenPills, savePillsLayout/saveLayout/setPillActive and selected
  ID accessors use native snapshots/CAS. The four layout ConfigItems are projected
  through that API. Numeric ambiguity in raw comma-separated aliases raises a named
  error; the typed list preserves both identities.
- Getter reuse consumes one native CAS receipt, not one per read (native limit is
  32/owner). Explicit loadConfig(True) refreshes; successful save reads the merged
  native layout. Conflict preserves the draft and old revision for explicit recovery.
- ui permission for registration/updates; ui+settings for layout. Native C owner
  provenance, grants, selection validity and durable mapping remain authoritative.

PillInfo icon colors remain source data; v1 rendering follows the native theme.
Portable icon strings are SF Symbol names (an `sf:` prefix is accepted). Numeric
Android drawables require an explicit mapping and fail rather than become zero.

## Exact v1 boundaries

The five methods do not expose global native PillInfo enumeration, registration
batching, global invalidation or layout reset. Corresponding SDK methods report
those missing operations by name. Built-in native-only creators are not fabricated
as Android views. Current owned registrations remain inspectable.

## Checks

Bounded SDK scenarios cover dual accessors, actual creator arity, native ID aliases,
opaque-ID collisions, persistent mapping reuse, CAS conflicts, separate UI/settings
permissions, concurrent selections, account retirement, stop failure, void results,
longPress Bool and admission-failure/terminal handle cleanup. These are strict wire
unit recorders; native bridge/provider execution and UIKit frames belong to the
native Pill/coordinator gates.
