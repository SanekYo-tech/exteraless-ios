# CMC-12 — both browser gesture gates

The coordinator connected the shipping browser root to both independent native
gesture gates. `ExteralessBrowserGestures(navigationView:)` keeps the modal-dismiss
Boolean current and supplies the existing horizontal-navigation predicate. The
per-page WebKit back/forward preference remains on its existing helper.

The native UIView category's modal getter also needed a correction: it returned
the NSNumber pointer as Bool, so writing `false` still read as true. It now reads
`boolValue`, matching the adjacent Boolean properties. This is required for reset
and live re-enabling of browser gestures.

`Tests/Exteraless/BrowserGestureContractsTests.swift` contains two small UIKit
contracts: true→false native property semantics and a real Core preference
observation/reset driving both root gates. The fixture creates no browser page,
WebKit process, Account, URL request or real gesture. Compile it with the shipping
`BrowserUI/Sources/ExteralessBrowserGestures.swift` plus Display/Core dependencies
in the bounded native integration suite. XCTest has not run on this Windows host.

Recorded compact-browser pull-down and horizontal-back on/off/reset remain the
visual/gesture acceptance gate. Controls and page scrolling keep their native paths.
