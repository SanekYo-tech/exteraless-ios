# UIKit native-test compilation — 43807905674 / 4269bdde

The full Telegram and Harness build, linkage and packaging checks passed. The
retained simulator Harness IPA SHA-256 is
`d6d9238a526b077ab4098aa0471a95df54a846af88e67337312adbc8ae8f6649`.
No recorded-frame acceptance is inferred from the archive.

Native test compilation rejected `DispatchSemaphore.wait` inside an async Task
in `PluginManagerAuthorityTests`. The fixture now awaits a checked continuation;
an ordinary DispatchQueue worker performs the same bounded wait and actual
preferences write. Authority revocation still occurs before gate release, and
every original file/state/no-publication assertion remains required.

The native test compile command now uses `--keep_going` to collect independent
target errors in one pass. Per-class execution deadlines and strict success
requirements remain separate and unchanged. This source correction requires the
next native compilation/execution gate.
