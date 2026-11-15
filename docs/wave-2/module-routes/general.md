# General — 14 exact source routes

[`general.json`](general.json) covers all **14/14** Original public method
identities, including exact file/name/parameter types. The coordinator read both
Original source files and the concrete native consumers. JSON identity equality,
all route paths and named anchors were checked; `ported`/`verified` remain false.

The map distinguishes native client flows from an exported Java helper method:

- Content capture is the native opt-in for Siri interaction donation.
- Download level controls actual FetchV2/MultipartFetch request budgets.
- Crash reports use opt-in bounded local MetricKit collection and manual export.
- File-folder validation operates inside a user-selected Files destination, with
  its documented 200-byte/error semantics rather than Android's 255/default fallback.
- Text editing, initialization and reload use the real native settings lifecycle.
- Android SharedPreferences/type-map utilities and the old Nagram settings entry
  keep exact unavailable dispositions.

Two concrete callable-reader defects were fixed in **d7d499f7**:
`GeneralConfig.contentCapture()` and `crashReports()` now reach their existing
native keys. The reproducing regression and 30/30 Python3.12/3.14 results are in
[`sdk-general-scalar-readers.md`](../sdk-general-scalar-readers.md).

The three aggregate reset routes were absent at this snapshot. Their exact source
scope is recorded rather than treating a single-key reset or batch primitive as
an implemented aggregate action. A separate owner is implementing that follow-up
in `settings-reset-scopes.md`; this map does not pre-claim its result.

Source boundary: **d7d499f7**. Map SHA-256:
`53a522771fede9455b8d4a8c02f063cfae2604f2ad7542f1c94b77aee69fcae7`.
The Original method set comes from `client-features.json`'s `modules.general`.
UI rendering, external file providers, actual MetricKit delivery and the completed
aggregate reset actions require their own native evidence.
