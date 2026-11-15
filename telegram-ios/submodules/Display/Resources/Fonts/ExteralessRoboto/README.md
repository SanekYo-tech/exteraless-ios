# Bundled interface family

Unmodified Roboto 3.015 upright and italic variable fonts, **1,019,528 bytes**
total, licensed under the accompanying SIL Open Font License 1.1. `pins.json`
records immutable distribution/source commits, URLs, byte counts, SHA-256,
upstream Git blob identities and axis ranges. The embedded names remain Roboto;
only the filenames have an Exteraless prefix to avoid flat-bundle collisions.

`Display/ExteralessFontFamily.prepare()` validates the pinned bytes and registers
the two faces in the current process, once. The application and each consuming
extension/test host must stage both TTFs and `ExteralessRoboto-OFL.txt` at their
own main-bundle root. They are registered explicitly, rather than by UIAppFonts.

The checked-in WebRTC example has a licensed 2014 static Roboto Regular. Its
identity and reason for using a matched variable pair instead are in the pins.
This is a native Roboto-family equivalent of Android's base asset choice, not a
claim that the absent Android asset files have identical bytes/metrics. Apple's
system family remains the default. No Google Sans/Pixel heuristic is used.

Integration patches, verification commands and required native frames are in
`docs/wave-2/font-family-parity.md` at the workspace root.
