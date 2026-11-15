# Native Monet color math

Seven unmodified Swift files from Google's Material Color Utilities,
commit `194144d75ed7d34f06264a625e086db81a7ab9aa` (Apache-2.0).
They are compiled directly by TelegramPresentationData's existing recursive
source glob. No SwiftPM/network dependency or build-time generator is added.

Only source paths were flattened. SHA-256 receipts are in
`docs/wave-2/monet-source-pins.json`. The original license bytes are retained as
`MaterialColorUtilities-LICENSE.txt`.

`ExteralessMonetPalette.swift` is the native adapter: it generates five HCT
palettes from a selected native accent, follows Original MonetHelper's discrete
tone/shade table and its intermediate-tone projection, and supplies neutral-link
coloring and harmonization. It never asks iOS for Android wallpaper colors.

`exteraGram-LICENSE.txt` and `ExteralessMonet-NOTICE.txt` accompany the separate
Classic surface-token references. These are not Google's source or a claim that
the missing Original Telemone/Classic/AMOLED asset set has been recovered.

The exact native integration/build/resource patch and validation limits are in
`docs/wave-2/monet-parity.md`.
