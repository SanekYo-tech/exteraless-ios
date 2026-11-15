# GeneralConfig native scalar readers

The General module's exact-method reconciliation found that `contentCapture()`
and `crashReports()` raised `TypeError: this ConfigItem has no source scalar getter`
even though their `Bool()` field reads and native definitions were available.
The owned `general_scalars` regression reproduced that failure before the fix.

The generator now recognizes only these two exact Original wrappers:
`loadConfig(false); return <same field>.Bool()`. Native Root owns initialization;
the resulting ConfigItem call reads `privacy.contentCapture` or `tools.crashReports`
through the existing guarded native setting service. A different body, a forced
reload or another method is not treated as this reviewed reader.

- Siri interaction donation remains the iOS adaptation of content capture.
- Crash reports remain opt-in local MetricKit collection, with manual export.
- Neither reader changes data or bypasses settings permission/owner checks.
- Android `loadConfig`, `getPreferences` and broad reset APIs remain explicit
  unsupported utility calls; no successful no-op was substituted.

After regeneration, the generator/binding cohort passed **30/30** on Python3.12
(20.35s) and3.14 (15.88s). The new regression exercises both call syntaxes, a real
SDK context, a strict service recorder, updated persisted values, revoked settings
permission and a missing native definition. These are not native execution claims.
The exact308 ExteraConfig IDs/counts remain **276/0/32**, with508 field bindings.
The new manifest's native snapshot is subsequent to Mac run20.
