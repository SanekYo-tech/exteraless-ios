import Foundation

private struct JavaValueFixtureError: Error {
    let message: String
}

/// Compile with the production TLCodec.swift and TLSchemaGenerated.swift.
/// The Python parent supplies adapter output and enforces a 20-second timeout.
@main
private enum JavaValueCodecFixture {
    static func main() throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard data.count <= 32_768,
              let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cases = input["cases"] as? [[String: Any]], cases.count <= 16 else {
            throw JavaValueFixtureError(message: "Invalid bounded codec input")
        }
        let codec = ExteralessTLCodec()
        guard input["sourceSHA256"] as? String == codec.sourceSHA256,
              let layout = input["nativeLayoutHash"] as? String,
              UInt64(layout, radix: 16) == codec.nativeLayoutHash else {
            throw JavaValueFixtureError(message: "Compiled native TL schema differs from Python metadata")
        }
        var output: [[String: Any]] = []
        for row in cases {
            guard let name = row["name"] as? String, let requestJSON = row["request"] else {
                throw JavaValueFixtureError(message: "Missing case name/request")
            }
            do {
                let value = try ExteralessTLValue(jsonObject: requestJSON)
                let request = try codec.encodeRequest(value)
                let normalized = try codec.decodeRequest(request.body)
                guard row["reject"] as? Bool != true else {
                    throw JavaValueFixtureError(message: "Invalid byte field accepted: \(name)")
                }
                output.append(["name": name, "normalized": normalized.jsonObject])
            } catch let error as ExteralessTLError {
                guard row["reject"] as? Bool == true, error.kind == .malformed,
                      error.message.contains("bytes") else {
                    throw error
                }
                output.append(["name": name, "rejected": true, "error": error.message])
            }
        }
        let result = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        FileHandle.standardOutput.write(result)
    }
}
