# Full iOS compile: first source blockers

Run `43736634873 / e8484ec0` passed package loading and reached actual iOS
compilation. Its repeated errors have three root causes:

- New annotated MtProtoKit declarations activated nullability-completeness errors
  in neighboring legacy method signatures. Explicit `_Null_unspecified` retains
  their prior imported contract while completing the header annotations.
- `FileManager.homeDirectoryForCurrentUser` is unavailable on iOS. The settings
  durability-root default now uses `URL(fileURLWithPath: NSHomeDirectory(),
  isDirectory: true)`, the actual process home on iOS and desktop platforms.
  The corresponding native-capable path fixture uses that API too.
- The Postbox message-history registration used implicit strong `self` outside a
  nested weak capture. The outer capture is now explicit, preserving the original
  short registration lifetime and weak disposable cleanup.

The next supported full build must typecheck these changes. No compiler warning
policy or native ownership checks were disabled. PostboxImportCheck passed.

Independent Mac component `43737993772 / e2a5684c` hit a cold **20-second compiler**
timeout in the original Foundation UI fixture before it reached SDK execution.
That driver now uses the existing process-tree-bounded launcher with a separate
120-second compile budget and 25-second execution budget. It retains the same
fixture source set and assertions; this is not a longer SDK/plugin runtime limit.
