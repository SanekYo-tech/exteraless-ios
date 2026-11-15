# Frozen production full-app build handoff

**Ready for the coordinator's single supported unsigned full-app compile with
`--continueOnError`.** Target: `//Telegram:Telegram`. UI source publication is
`2bac089c`, including `4476f853`, Layout `19c1a96a`, renderers `b06f959b`, SDK
`46393e31` and AI UTF-16 repair `230cb7c0`. The sealed local source HEAD is
`96bff39e89dc889d410821242139d78339c70185`, adding the Tools CorePath boundary repair.
The later probe-only `a9afcb79` changes have no overlap with these production inputs.

## Frozen delivery

Receipt directory:
`build/wave-2-dependencies/production-app-freeze-2bac089c/`.

- `frozen-production-paths.txt`, `.sha256`, `.json`: **947** production BUILD,
  MODULE/lock, Make, workflow, runtime-tool and pinned resource paths and raw hashes.
- `production-delivery-paths.txt`: **102** pending working-tree files from that frozen set.
- `production-imports.json`, `production-graph.json`: source owners, actual
  dependency routes, six extensions and the single static Core owner.
- `production-source-inventory.json` / `.sha256`: all audited production Swift bytes.
- `runtime-staging.json`, `runtime-source-inventory.json` / `.sha256`,
  `staging-audit.json`, `header-staging.json`: fresh, validated offline staging.
- `root-resources.json`, `frozen-rust.json`, `source-cohort.json`, `gitlinks.json`:
  exact resource placements, frozen Rust postimages and source publication identity.
- `production-inputs.sha256`: the joined declaration/tooling/source/resource seal.
- `checks.json` and `receipt-manifest.sha256`: final local checks and receipt hashes.

Hashes describe raw local bytes, including line endings. The normal preparer emits
the byte-exact staging inventory of the coordinator's selected checkout. The older
native/component receipts remain independent checkpoints.

## Completed production audit

| Check | Result |
| --- | --- |
| Production Swift source ownership | 5,113 files, 737 owners; all 782 Swift paths in the published UI handbacks reach the app graph |
| Actual project-module imports | 27,515 checked: 26,213 direct and 1,302 resolved through the pinned rules_swift transitive module inputs |
| Missing production imports / unresolved published source owners | **0 / 0** |
| Reachable declared app graph | 885 targets across 817 BUILD files; six extensions |
| Frozen BUILD/MODULE syntax | 829 files parsed; Python/JSON tooling parsed and scoped diff whitespace checked |
| Postbox import/access preflight | Passed with the existing allowlists |
| Fresh runtime staging | 414 source pins, 3,267 staged files, 547 Python assets, 12 distributions |
| Runtime slices | Device + simulator arm64; 55 dynamic frameworks each; native candidate admission empty |
| Compile headers | Device 215 / simulator 216 `.h` files, plus one modulemap each; 90 private compatibility headers each |
| Resource/packaging verification | 22 packaging checks and two resource checks passed; relocated staging rejects a missing resource contract or changed font |

The import receipt records the two `canImport(AppCenter)` imports and six
non-iOS conditional imports explicitly. The existing rules_swift module-map
implementation supplies the recorded transitive imports. All mandatory direct
ExteralessCore/Host/Hooks and integration-module edges also pass.

Core ownership is `TelegramCoreFramework -> TelegramCore ->
//third-party/exteraless:ExteralessCore ->
@exteraless//swift/ExteralessCore:ExteralessCore`. TelegramUIFramework uses the
Core framework and owns the static Host/Hooks/C bridge; Python remains dynamic.
The export-list rule consumes the actual transitive static archives. Core has no
PasscodeCore/TelegramCallsUI edge, and PluginHost has no Core edge.

### Source and staging fingerprints

| Inventory | SHA-256 |
| --- | --- |
| Audited production Swift sources | `7ae6a0579228f1a9b7b55933a11eefdf17968fbbfc54cd5109106d69a1cf17f8` |
| Runtime source inputs | `3047f4d42525e107b12dd7374e3e11f381d344bec924d8e3aba88caed1dba414` |
| Staged runtime files | `c9c424c899a00d902755d730c278e9a6acdbdce0cd6ae3e9f685eb24fc33b201` |
| Pinned support archive | `4eea2c76ad70f2df8c1767489315a16d72cd96ce5c086412ee2d154c3bd8e257` |
| Frozen Rust source provenance | `9ca7ac71a7540ec3a2ef52b2fda5318580f1f5fe4a97611e53a29c7372b315fd` |

Inventory hashes use sorted UTF-8 lines of `<raw SHA-256>  <repository path>\n`.
Rust retains its established JSON provenance fingerprint. Its gitlink is still
`160000 da4b2170210aab0430c4ff18c032991f3030cf45`; the 15,922-byte outer patch is
`f1bbe44f47990d0f97df34d4a897abc3306b181de793875eae7410d562828cce`.
Patch, manifest, helper and all three nested postimages retained their bytes/mtimes.

## Production resource contract

`telegram-ios/build-system/Make/NativeBundleResources.py` is the shared validator.
The preparer checks its contract and all six Font/Monet pins and includes them
in the source inventory. `RuntimePackaging.load_staging_manifest` rechecks them
before/after Make; `RuntimePackaging.py --ipa ...` verifies the actual IPA.

| Process bundle root | Required resources |
| --- | --- |
| `Payload/Telegram.app/` | Roboto Regular + Italic + OFL, all three Monet notices, AdGuard filter + license |
| `Payload/Telegram.app/PlugIns/ShareExtension.appex/` | Roboto Regular + Italic + OFL |
| `Payload/Telegram.app/PlugIns/NotificationContentExtension.appex/` | Roboto Regular + Italic + OFL |

These are eight pinned source files at fourteen declared destinations. The
validator rejects wrong bytes, missing/nested/duplicate placement and Roboto
`UIAppFonts` entries. Display performs explicit font registration. Python's
sealed vendor inventory, PEP 730 markers, dynamic load paths and all six
extension rpaths retain their production checks. Pillow/lxml OWN_GIL admission
remains closed; cached downloads still require the pinned checksum and TLS.
The Font, AdGuard and Monet resource paths carry byte-preserving Git attributes.

## Coordinator execution

`.github/workflows/ios-build.yml` is manual-only and runs the production unsigned
plumbing and runtime-packaging checks, prepares the pinned source/runtime inputs,
then invokes the supported full app build. It selects Xcode **27.1**, preserves
the unsigned aquery preflight, and retains diagnostics and successful-action
caches on a failed compile. Its Make invocation is:

```sh
cd "$SOURCE_DIR"
python3 -u build-system/Make/Make.py \
  --bazelUserRoot="$BAZEL_USER_ROOT" \
  --cacheDir="$BAZEL_DISK_CACHE" \
  build \
  --configurationPath=build-system/exteraless-configuration.json \
  --unsigned \
  --continueOnError \
  --configuration=release_arm64 \
  --buildNumber="$BUILD_NUMBER" \
  --outputBuildArtifactsPath="$SOURCE_DIR/build/artifacts"
```

`--continueOnError` forwards to Bazel `--keep_going` and preserves a nonzero
result when compilation fails. The workflow's preceding prepare step uses the
same source checkout and verified support/wheel caches. After a successful build,
the existing unsigned-IPA and RuntimePackaging commands validate
`build/artifacts/Telegram.ipa` and emit the artifact manifests and entitlement
templates.

Apple compilation and runtime/frame acceptance are coordinator-run evidence.
This handoff supplies the frozen production inputs for that compile; Core runtime
test repairs can be evaluated through their existing component workflow.
