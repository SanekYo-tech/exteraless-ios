# Darwin AI UTF-16 boundary correction

Mac component `43728873627 / 46393e31` compiled Core and executed its suite.
`AITranslationTests.testFormattingRoundTripsCrossingSpansUTF16AndSelection` found
that Darwin accepted an NSRange splitting a surrogate pair where corelibs rejected
the same `Range(NSRange, in: String)` conversion.

`AITextFormatting.swift` now checks UTF-16 bounds and both Unicode-scalar boundaries
explicitly before selection, span encoding and original-span decoding. No
substring is formed from one half of a surrogate pair. Combining-mark and ZWJ
scalar boundaries remain legal Telegram UTF-16 coordinates.

The original failing assertion stays. A new bounded regression covers both halves
of two supplementary scalars, a zero-length invalid caret, encoded/original span
validation, complete emoji selection and a combining-mark span round-trip.
The correction still needs its next Swift/Mac run; it is not a result for the
remaining Darwin storage failures from that component snapshot.
