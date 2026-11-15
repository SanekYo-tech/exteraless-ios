# Settings shape contract (AI04)

The names match the requested API. Native definitions can append the optional
`valueShape: ClientSettingShape? = nil` argument to `ClientSettingDefinition`.

```swift
public indirect enum ClientSettingShape: Equatable, Sendable {
    case any, null, bool, integer, number, string
    case array(ClientSettingShape, maximumCount: Int)
    case object([String: ClientSettingShape], required: Set<String>)
}
```

Objects are closed: keys outside the field map are rejected, and every required
field must be present. Arrays check the count limit before walking elements.
Schema/value depth is bounded at 60. `.number` accepts integers; `.integer` also
accepts exactly representable integral numbers; booleans are neither. Validation
does not coerce strings. `.any` still requires finite, bounded JSON.

Example for the AI owner (choose the actual count limit and required fields):

```swift
valueShape: .array(.object([
    "id": .string, "name": .string, "url": .string, "model": .string,
    "reasoningEffort": .integer, "wireProtocol": .string
], required: ["id", "name", "url", "model"]), maximumCount: 64)
```

An unlisted `apiKey`/credential field is rejected instead of persisted or exposed
in snapshots/export. The definition owner supplies the closed schema; Core has no
AI-specific field list. Nil preserves the previous validation behavior. Shapes
participate in definition equality and apply to defaults, options, registration,
loading and every setter. Invalid values throw `invalidValue(..., reason: .shape)`;
invalid schemas throw `invalidDefinition`. No validation closures are accepted.

Strict raw JSON entry point for the bridge/coordinator:

```swift
ClientSettingValue.decodeJSON(_ data: Data) throws -> ClientSettingValue
ClientSettingValue.decodeJSON(_ text: String) throws -> ClientSettingValue
```

It receives original JSON bytes/text, before Foundation `JSONSerialization` or
another numeric re-encoding. Unsupported integer tokens are rejected rather than
rounded. All integer-valued spellings must fit Int64. Fractional values use a
finite Double whose decimal round-trip spelling must match the token; excess
precision and underflow are rejected explicitly. Native bridge code should decode
the entire request root with this API. Generic Codable decoding remains available
for trusted model serialization; original-byte integrity uses `decodeJSON`.
Implementation/regression status is recorded in `settings-remediation.md`.
