import Foundation
internal import TelegramApi

/// Actual native fields, not debugDescription/Mirror strings. The native schema
/// descriptor supplies camel-cased field names; the bridge schema maps them back.
/// This preserves real fields on synthesized short-message updates that are not
/// represented by the short constructor's flags during naive reserialization.
func exteralessTLNativeSnapshot(_ value: Any) throws -> ExteralessTLValue {
    var remaining = ExteralessTLCodec.maximumValues
    func snapshot(_ value: Any, depth: Int) throws -> ExteralessTLValue {
        guard depth <= ExteralessTLCodec.maximumDepth, remaining > 0 else { throw ExteralessTLError(.limit, "Native TL snapshot exceeds its value budget") }
        remaining -= 1
        if let value = value as? TypeConstructorDescription {
            let (name, fields) = value.descriptionFields()
            var object: [String: ExteralessTLValue] = ["_": .string(name)]
            for (fieldName, field) in fields {
                let key = try ExteralessTLCodec.shared.canonicalNativeField(fieldName, constructor: name)
                if let field = field.value { object[key] = try snapshot(field, depth: depth + 1) }
            }
            return try ExteralessTLCodec.shared.reconcileNativePresence(object)
        }
        if let bytes = value as? Buffer { return .bytes(bytes.makeData()) }
        func words(_ values: [Int64]) -> ExteralessTLValue {
            var data = Data()
            for var value in values.map({ $0.littleEndian }) { withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
            return .bytes(data)
        }
        if let value = value as? Int256 { return words([value._0, value._1, value._2, value._3]) }
        if let value = value as? Int128 { return words([value._0, value._1]) }
        if let values = value as? [Any] {
            guard values.count <= ExteralessTLCodec.maximumVectorCount else { throw ExteralessTLError(.limit, "Native TL vector exceeds its limit") }
            return .array(try values.map { try snapshot($0, depth: depth + 1) })
        }
        return try ExteralessTLValue(jsonObject: value)
    }
    let result = try snapshot(value, depth: 0)
    if let name = result["_"]?.stringValue, let type = ExteralessTLCodec.shared.typeOfConstructor(name) {
        return try ExteralessTLCodec.shared.normalize(result, as: type)
    }
    return result
}

func exteralessTLParseUpdate(_ value: ExteralessTLValue) throws -> Api.Update {
    let data = try ExteralessTLCodec.shared.encode(value, as: "Update")
    let reader = BufferReader(Buffer(data: data))
    guard let id = reader.readInt32(), let result = Api.parse(reader, signature: id) as? Api.Update else {
        throw ExteralessTLError(.schema, "Native Update parser rejected validated TL")
    }
    return result
}
