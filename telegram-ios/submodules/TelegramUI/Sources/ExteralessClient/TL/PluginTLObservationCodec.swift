import Foundation
import PluginHooks
import TelegramCore

/// Call on PluginHooks' observation queue, before hopping to main. Preserves the
/// original observation and adds decoded real fields; this is not a mutation gate.
public enum PluginTLObservationCodec {
    public static func hookName(_ canonicalName: String) -> String {
        return ExteralessTLCodec.shared.androidHookName(canonicalName)
    }

    public static func jsonString(_ event: PluginHookObservation) throws -> String {
        let original = try event.jsonString()
        guard var object = try JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any] else {
            throw ExteralessTLError(.malformed, "Invalid native TL observation")
        }
        do {
            let value: ExteralessTLValue?
            switch event {
            case let .preRequest(request):
                if let data = request.serializedTLBytes, request.tlBytesEncoding == .requestBody {
                    value = try exteralessTLObservationValue(body: data, requestBody: true)
                } else {
                    value = nil
                }
            case let .postRequest(request):
                if let data = request.serializedTLBytes {
                    switch request.tlBytesEncoding {
                    case .responseBody:
                        value = try exteralessTLObservationValue(body: data, requestBody: false, methodName: request.metadata.requestName)
                    case .boxedTL:
                        value = try exteralessTLObservationValue(body: data, requestBody: false)
                    default:
                        value = nil
                    }
                } else {
                    value = nil
                }
                if let error = request.error {
                    object["tl"] = NSNull()
                    object["tlError"] = ExteralessTLServiceError(code: error.code, text: error.message).value.jsonObject
                }
            case let .update(update), let .updates(update):
                value = try exteralessTLObservationValue(body: update.serializedTLBytes, requestBody: false)
            }
            if let value { object["tl"] = value.jsonObject }
        } catch let error as ExteralessTLError {
            object["tlDecodeError"] = ["kind": error.kind.rawValue, "message": error.message]
        } catch {
            object["tlDecodeError"] = ["kind": "MalformedRequest", "message": "Native TL observation decoding failed"]
        }
        // The metadata and observational flag are retained even if TL decoding
        // is unavailable/too large; never turn an incomplete observation into TL.
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if encoded.count > ExteralessTLCodec.maximumJSONBytes {
            object.removeValue(forKey: "tl")
            object["tlDecodeError"] = ["kind": "ResourceLimit", "message": "Decoded TL observation exceeds 16 MiB"]
            let fallback = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard fallback.count <= ExteralessTLCodec.maximumJSONBytes else {
                throw ExteralessTLError(.limit, "Original TL observation exceeds 16 MiB")
            }
            return String(decoding: fallback, as: UTF8.self)
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}
