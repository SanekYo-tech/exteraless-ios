# Tools original-ID completion receipts

This closes the **missing-receipt** list in `docs/parity/wave-2-reconciliation.md:75–85`,
with a separate disposition for `etgbackup.ChatSwipeAction`. It does not promote
unexecuted native source or unapplied common hunks to verified parity.

Data-loss/security work takes precedence: `tools-remediation.md` records TB-01–07 and
CA-01/02; `tools-schema-evidence-contract.md` is the HNS-01 joined-patch contract.
The three independent review reports remain unchanged.

Android paths below are relative to
`third_party/exteraless-android/TMessagesProj/src/main/`.

## All 14 original fields

Declaration anchors (type/default above are taken from these actual definitions):
`kotlin/xyz/nextalone/nagram/NaConfig.kt` — cameraInVideoMessages **1405**,
disableCrashlyticsCollection **865**, enhancedVideoBitrate **515**,
noiseSuppressAndVoiceEnhance **136**, performanceClass **1081**, showRPCError **199**;
`java/tw/nekomimi/nekogram/NekoConfig.java` — cachePath **130**, customAudioBitrate
**178**, disableAutoDownloadingArchive **176**, disableAutoDownloadingWin32Executable
**175**, disableInstantCamera **82**, enhancedFileLoader **179**, rearVideoMessages
**117**, uploadBoost **180**.

| Original ID; type / declaration default | Actual original behavior | iOS receipt / precise limit |
|---|---|---|
| `nagram.cameraInVideoMessages`; int / 1 | `NaConfig.kt:1404–1408`: 0 front, 1 rear, 2 ask. `fixConfig:1618–1620` changes absent new preference from legacy RearVideoMessages, false→front. `InstantCameraView.java:862–865` selects facing; `ChatActivityEnterView.java:996–1006,5069–5077` asks **before** recording. | **Applied front/rear/ask**: `tools.videoMessageCameraFacing`, default 0 (effective fresh-install Android behavior), drives both Legacy/Neo configurations. The native State start gate presents Ask over the preview, defers recordingStartTime and camera.startRecording, waits up to two seconds for the chosen position, then starts hands-free. Cancel/retirement invalidates callbacks and dismisses the owned dialog. Remembering preserves Ask and explicit facing wins over the old fallback. The stock `videoMessageCameraMode` is a backend/quality selector, not this feature. Native frames remain pending. |
| `nagram.disableCrashlyticsCollection`; bool / false | No independent active collection consumer. `GeneralConfig.kt:144–147` migrates true to `crashReports=false` and clears the old flag. False does nothing. | **Migrated alias** of existing `tools.crashReports` / actual MetricKit collection in ToolsIntegration. Legacy true imports false; legacy false does not enable diagnostics. iOS collection is local/manual-export, not Firebase upload. No duplicate switch. |
| `nagram.enhancedVideoBitrate`; bool / false | `MediaController.java:7477–7487` raises caps at 720/1080/1440/2160; constants `:1009–1012`: 6.8/14/28.4 Mbit/s enhanced rungs. `:7489–7498` still bounds by source bitrate, resize and compression factors. | `ToolsNativeModePolicy.videoBitrateKbps` is implemented; **coordinator consumer hunk supplied**, not applied, in `tools-mode-hunks.patch` for `MediaEditorValues.recommendedVideoExportConfiguration` before AVVideoAverageBitRateKey. It raises eligible native targets, preserves higher native targets and leaves round/sticker/avatar budgets alone. This API has no original source bitrate input, so it is not claimed to reproduce Android's remeasurement formula or all legacy TGMediaVideoConverter paths. |
| `nagram.noiseSuppressAndVoiceEnhance`; bool / false | `AudioEnhance.kt:17–44` conditionally enables available Android AGC/AEC/NS effects on AudioRecord's session; actual voice consumer `MediaController.java:5481`, video/audio capture `utils/recorder/audio/AudioCapture.java:153`. | **Coordinator hunk supplied** for ordinary `ManagedAudioRecorder.setupAudioUnit`: Apple VoiceProcessingIO with AGC/bypass settings, fall back to the existing RemoteIO unit if unavailable. Its managed audio-session lease stays authoritative. The separate AVCapture round-video audio pipeline is not an AudioRecord session and is not covered by this voice-note hunk. No fictitious DSP-quality or capture-output claim. |
| `nagram.performanceClass`; int / 0 | `SharedConfig.java:1830–1849`: 0 measure, 1 high, 2 average, 3 low, cached globally; `:1852+` measures Android version/SoC/sysfs CPU/memory. `LiteMode:52–86,206–214`, `AnimatedEmojiDrawable:608–640`, `ImageLoader:978`, `DrawingInBackgroundThreadDrawable:235` and `ThanosEffect:1114–1135` connect that class to real animation/effect work. | **Defined iOS adaptation; shared integration staged**: `ToolsPerformancePolicy.swift` implements 0 native automatic, 1 up-to-60-fps High, 2 30-fps Average with reduced translucency/effects/background work, 3 static cached animations and no automatic playback/loops. Native false preferences and system/battery/thermal/background limits remain ceilings. New energy bridge and per-target/clock helpers are supplied; exact SharedAccountContext, DCT/Subcodec, chat relayout and prefetch consumers plus separate Root registration are in `performance-native-hunks.patch` / `performance-registration-hunk.patch`. `performance-parity.md` defines APIs and staging. The receipt key remains null until these consumers are actually applied; no unused enum is registered in frozen ToolsFeatures. |
| `nagram.showRPCError`; bool / false | `ConnectionsManager.java:488–496` sends the normalized request and server error text to ErrorDatabase.showErrorToast, independently of ordinary logging. | **Bounded code-only diagnostic adaptation**: `ToolsRPCFailureBuffer` and Tools Diagnostics reader/export are applied. The central `NetworkEngineRequest.completed` producer and definition registration are in the coordinator patch. It covers both engines when applied, uses method/code only and suppresses even method metadata for credential-classified requests. No raw error text, request arguments or unbounded UI fanout; CA-04's logging redaction remains with its owner. It is not yet a connected producer or an Android toast clone. |
| `neko.cachePath`; text / empty | `FilesMigrationService.java:90–108,218–224` reads the old Neko folder and its audios/documents/images/stories/videos/caches subfolders to migrate to Android getExternalFilesDir()/Telegram. No active cache-picker/control consumer was found. | **Android legacy-path migration state, unsupported input**: iOS Postbox builds the real MediaBox at its account-owned `basePath + /media` (`Postbox.swift:4750`). An Android absolute path conveys neither that data layout nor a sandbox grant. General backup does not adopt it. `tools.customSavePath` is a Files export destination, not this cache-path field. No duplicate/inactive path control. |
| `neko.customAudioBitrate`; int / 32 | `NativeInstance.java:72–84` passes a short to **makeGroupNativeInstance**, not ordinary voice-note or private-call recording. `NekoExperimentalSettingsActivity.java:367–391`: 32/64/128/192/256/320 kbit/s. | `ToolsNativeModePolicy.groupAudioBitrate` plus **coordinator hunk** in `PresentationGroupCall` feeds its actual `outgoingAudioBitrateKbit` parameter. Native 0 means preserve server/native default (normally 32); explicit options match the original list. No claim for private calls, AAC video audio, or Opus voice notes. Definition is not registered before the consumer hunk. |
| `neko.disableAutoDownloadingArchive`; bool / true | `AndroidUtil.java:145–165`: exact APK/ZIP/7z/TAR/GZ/ZST/ISO/XZ/LHA/LZH extension list; last suffix, case-insensitive. RAR is not in the source list. | **Applied actual automatic fetch/prefetch gate**: `MediaAutoDownloadSettings.shouldDownloadMediaAutomatically` and `shouldPredownloadMedia` call `exteralessToolsAllowsAutomaticFileDownload`, consuming `tools.skipAutoDownloadArchives=true`. Normal PrefetchManager and ChatMessageFileBubbleContentNode use those decisions before automatic fetch. It is not an ad filter; explicit manual fetches remain their native action paths. |
| `neko.disableAutoDownloadingWin32Executable`; bool / true | `AndroidUtil.java:142–165`: CMD/BAT/COM/EXE/LNK/MSI/PS1/REG/VB/VBE/VBS/VBSCRIPT filename list. | **Applied**, same two ordinary native decision points, with `tools.skipAutoDownloadExecutables=true`. Independent of archive toggle and of MIME/ad classification. New eligibility decisions are gated; already admitted transfers retain their native cancellation/lifetime. |
| `neko.disableInstantCamera`; bool / true | `ChatAttachAlertPhotoLayout.java:2482–2491` suppresses automatic camera preview/thumbnail; `:1575–1580` initializes on explicit camera click. Android retains its static camera tile. | **Reuse existing** `chats.hideCameraTile` consumer in `MediaPickerScreen:753–789`; it prevents creation/start of the automatic live camera tile, with explicit camera attachment still available. Native default is false, different from the old Neko default true; native also removes the tile rather than retaining Android's static icon. Legacy alias maps to that existing key only when canonical hideCameraTile is absent. No second control is added; stronger tile behavior is stated, not hidden as exact equivalence. |
| `neko.enhancedFileLoader`; bool / false | Only live reference is `GeneralConfig.kt:137–142`: true is cleared and upgrades downloadSpeedBoost 0→1. No independent current loader branch. | **Migrated alias**, existing `tools.downloadSpeedBoost`, consumed by both MultipartFetch/FetchV2. Legacy true upgrades a missing/zero value; an explicit higher new profile wins. False is not imported as a downgrade. This does not cover uploadBoost or encoder/capture features. |
| `neko.rearVideoMessages`; bool / false | Compatibility wrapper plus raw-key migration in `NaConfig.kt:1618–1620` to cameraInVideoMessages. New field wins when present. | **Migrated alias**, same applied `tools.videoMessageCameraFacing` consumer. Legacy bool becomes 0/1; newer cameraInVideoMessages presence wins, including Ask=2. No duplicate rear-camera switch. |
| `neko.uploadBoost`; bool / false | `FileUploadOperation.java:334–351`: minimum chunk 128→512 KiB outside slow-network rules; request count is still derived from its in-flight byte budget. It is not downloadSpeedBoost and not a parallelism multiplier. | **Applied** `tools.uploadBoost` at actual MultipartUploadManager construction and complete-resource part-size selection. A 512-KiB floor applies only before any part is started, to complete unencrypted/headerless resources >256 KiB. Streaming/secret/delayed-header geometry and native 3/30 parallelism stay native; already-large 512-KiB uploads are unchanged. No throughput result is claimed. |

## `etgbackup.ChatSwipeAction` — separate raw mainconfig field

Original `EtgBackup.java:576`, int default **-1**, carries SharedConfig's preference,
not an Exteraless boolean. `SharedConfig.java:1774–1790` chooses folders when filters
exist, archive otherwise; an explicitly chosen folders action also falls back to
archive without filters. `SwipeGestureSettingsView.java:30–35` defines
0 pin / 1 read / 2 archive / 3 mute / 4 delete / 5 folders.

Native `ChatListUI/Sources/Node/ChatListItem.swift:748–897` builds per-peer eligible
reveal actions; `:4010–4062` combines sides and the dialog owner's archive-swipe rule.
Folder paging is a separate ChatList controller/pager gesture. There is no native
global `ChatSwipeAction` preference to set as a one-key batch equivalent.

Disposition is **partial / explicit native-adapter gap**, not guessed import:
Tools reports this mainconfig field as ignored and does not broaden its admitted
write set into account/Postbox state. The Chat/Root owner must supply an eligible
primary-action projection after existing per-peer/dialog gates and before reveal
options are installed, plus folder-vs-row gesture ownership for value 5/-1. Reusing
an arbitrary native enum rawValue or adding a dead Tools control would be incorrect.
Native read/pin/archive/mute/delete affordances are source evidence, not proof that
the imported primary-swipe selector is implemented.

## Common mode / Root work

`tools-mode-hunks.patch` contains ready source edits for four common consumers and
their definition registration: video export bitrate, voice-note processing, group
audio bitrate and central RPC diagnostics. It preserves the CA-04 classified result
path and never collects raw RPC text. **Coordinator owns application**; build owner
owns the required ExteralessCore dependency edges. Helpers and bounded model tests
are already in `ToolsNativeModePolicy.swift` / `ToolsNativeModePolicyTests.swift`.
These definitions are deliberately not registered in the current ToolsFeatures
array until their actual consumers land.

The camera Ask route is applied in the native recording State entry. Unlike Android's
composer popup, it appears over an already-active camera preview; no recording or
recordingStartTime starts until selection. Its wait/dispose behavior and recorded
frames remain native acceptance items. ChatSwipeAction still needs the separate
eligible-reveal/folder gesture projection above; current stock actions remain usable.

## Checks / remaining proof

Portable tests supplied for exact extension lists, independent upload geometry,
camera-facing/remember precedence, legacy migrations, bitrate rungs and bounded
code-only RPC diagnostics. Native automatic-download/upload/capture/frame execution
has not been performed. Source hygiene and read-only parity merge are the available
local evidence; no source receipt is marked verified. No commit, push or CI dispatch.

Final source checks: **73 Swift files / 19 live Tools keys**, Postbox boundary and
diff/owned formatting passed; read-only merge has **43 feature receipts / 9 modules /
171 references / 0 verified added**. The 14 IDs and ChatSwipeAction all have explicit
feature receipts, including their partial/source-defined limits. **84 Core + 3 native
Tools XCTest methods are supplied, not run.** The common mode patch dry-applies in
memory to five files; native consumers remain coordinator-owned until actually applied.

Native frame expectations before recording: Ask shows a choice over preview with
no recording clock/progress; releasing the original hold does not schedule send or
preview transition; choosing a ready camera starts one hands-free recording; cancel,
timeout and retirement cannot start a late recording. Recovery shows actual admitted
counts and cached/fresh qualification, never API hashes or key-export permission
as an imported control. Files failure leaves no published wrong-source output.
Record self-owned fixture paths for at most 30 seconds each, then inspect timestamped
frames under AGENTS.md; no visual/runtime success is claimed here.
