import Foundation

/// Locally authored, CC0-1.0 test font: one rectangular outline at U+1F600.
/// Not a product emoji set; no external font, image or vendor artwork is copied.
/// The same source is included by the native font tests through a test-only label.
enum EmojiFontFixture {
    static let sha256 = "0e60fcc49115ab0bfc096118e3054a992f8b4fb917c0bdc601eda3e68dbfc5b7"
    static let base64 = "AAEAAAAKAIAAAwAgT1MvMmHmVE4AAACsAAAATmNtYXAAEuw1AAAA/AAAAChnbHlmBIYIDAAAASQAAAAwaGVhZGI2RAYAAAFUAAAANmhoZWEGpgRPAAABjAAAACRobXR4B9AAAAAAAbAAAAAIbG9jYQAAADwAAAG4AAAADG1heHAABAAFAAABxAAAACBuYW1lI105ZAAAAeQAAAGkcG9zdP+fADIAAAOIAAAAIAAAA+gBkAAFAAACigKKAAAASwKKAooAAAFeADIA+gAAAAAAAAAAAAAAAAAAAAACAAAAAAAAAAAAAABFWFRSAED/////A4T/nAAAA+gAyAAAAAAAAQADAAoAAAAMAAwAAAAAABwAAAAAAAAAAQAB9gAAAfYAAAAAAQAAAAAAAAAAAAAAAAABAGQAZAMgAyAAAwAAAQEBAQBkArwAAP1EAGQAAAK8AAAAAAABAAAAAQAAsUEEeV8PPPUAAwPoAAAAAAAAAAAAAAAAAAAAAAAAAAADIAMgAAAACAACAAEAAAAAAAEAAAOE/5wAAAPoAAAAyAMgAAEAAAAAAAAAAAAAAAAAAAACA+gAAAPoAAAAAAAAAAAADAAAADAAAQAAAAIABAABAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAYATgADAAEECQAAAEwAAAADAAEECQABACwATAADAAEECQACAA4AeAADAAEECQAEACwAhgADAAEECQAGACwAsgADAAEECQANAHgA3gBDAEMAMAAtADEALgAwACwAIABsAG8AYwBhAGwAbAB5ACAAYQB1AHQAaABvAHIAZQBkACAAdABlAHMAdAAgAGYAaQB4AHQAdQByAGUARQB4AHQAZQByAGEAbABlAHMAcwBFAG0AbwBqAGkARgBpAHgAdAB1AHIAZQBSAGUAZwB1AGwAYQByAEUAeAB0AGUAcgBhAGwAZQBzAHMARQBtAG8AagBpAEYAaQB4AHQAdQByAGUARQB4AHQAZQByAGEAbABlAHMAcwBFAG0AbwBqAGkARgBpAHgAdAB1AHIAZQBDAEMAMAAtADEALgAwADsAIAB0AGUAcwB0AC0AbwBuAGwAeQAgAHMAaQBuAGcAbABlACAAbwB1AHQAbABpAG4AZQAgAGUAbQBvAGoAaQAuACAATgBvACAAZQB4AHQAZQByAG4AYQBsACAAYQBzAHMAZQB0AHMALgADAAAAAAAA/5wAMgAAAAAAAAAAAAAAAAAAAAAAAAAA"
    static var data: Data { Data(base64Encoded: base64)! }

    static func put32(_ value: UInt32, at offset: Int, in data: inout Data) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - 8 * index)) }
    }

    static func checksum(_ data: Data) -> UInt32 {
        var sum: UInt32 = 0
        for offset in stride(from: 0, to: data.count, by: 4) {
            var word: UInt32 = 0
            for index in 0..<4 { word = word << 8 | UInt32(offset + index < data.count ? data[offset + index] : 0) }
            sum = sum &+ word
        }
        return sum
    }

    /// A structurally valid font whose cmap names a glyph without contours.
    /// Pure SFNT admission can pass; the real renderer must reject the blank font.
    static var blank: Data {
        var data = self.data
        data[304] = 0; data[305] = 0 // glyf[1].numberOfContours
        put32(checksum(data.subdata(in: 292..<340)), at: 12 + 2 * 16 + 4, in: &data)
        put32(0, at: 348, in: &data)
        put32(0xb1b0afba &- checksum(data), at: 348, in: &data)
        return data
    }

    static var narrow: Data {
        var data = self.data
        data[324] = 2; data[325] = 88 // second point's x delta, 700 -> 600
        put32(checksum(data.subdata(in: 292..<340)), at: 12 + 2 * 16 + 4, in: &data)
        put32(0, at: 348, in: &data)
        put32(0xb1b0afba &- checksum(data), at: 348, in: &data)
        return data
    }
}
