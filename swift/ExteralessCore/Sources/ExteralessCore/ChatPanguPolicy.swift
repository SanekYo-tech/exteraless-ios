import Foundation

/// Native adaptation of ws/vinta/pangu/Pangu.kt. Group splices retain attributed content;
/// protected spans (entities/code supplied by the caller) and entire URL tokens stay literal.
public enum ChatPanguPolicy {
    private static let protectedKey = NSAttributedString.Key("exteraless.pangu.protected")
    private static let cjk = "[\\u3040-\\u30ff\\u3100-\\u312f\\uf900-\\ufaff\\u4e00-\\u9fff]"
    private enum Piece { case group(Int), space }

    public static func applying(to value: NSAttributedString, protectedRanges: [NSRange] = []) -> NSAttributedString {
        guard value.length > 1, value.length <= 65536, protectedRanges.count <= 1024 else { return value }
        let result = NSMutableAttributedString(attributedString: value)
        for range in protectedRanges where range.location >= 0 && range.length >= 0 && range.location <= value.length && range.length <= value.length - range.location {
            result.addAttribute(protectedKey, value: true, range: range)
        }
        if let urls = try? NSRegularExpression(pattern: "\\S+://\\S+") {
            for match in urls.matches(in: result.string, range: NSRange(location: 0, length: result.length)) {
                result.addAttribute(protectedKey, value: true, range: match.range)
            }
        }
        @discardableResult func apply(_ pattern: String, _ pieces: [Piece], options: NSRegularExpression.Options = []) -> Bool {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
            var changed = false
            let matches = regex.matches(in: result.string, range: NSRange(location: 0, length: result.length))
            guard matches.count <= 4096 else { return false }
            for match in matches.reversed() {
                var protected = false
                result.enumerateAttribute(protectedKey, in: match.range, options: []) { value, _, stop in
                    if value != nil { protected = true; stop.pointee = true }
                }
                if protected { continue }
                let replacement = NSMutableAttributedString(string: "")
                for piece in pieces {
                    switch piece {
                    case let .group(index):
                        let range = match.range(at: index)
                        if range.location != NSNotFound { replacement.append(result.attributedSubstring(from: range)) }
                    case .space:
                        replacement.append(NSAttributedString(string: "\u{2009}", attributes: result.attributes(at: match.range.location, effectiveRange: nil)))
                    }
                }
                if replacement.string != (result.string as NSString).substring(with: match.range) {
                    result.replaceCharacters(in: match.range, with: replacement)
                    changed = true
                }
            }
            return changed
        }
        apply("(\(cjk))([\"'])", [.group(1), .space, .group(2)])
        apply("([\"'])(\(cjk))", [.group(1), .space, .group(2)])
        apply("([\"'])(\\s*)(.+?)(\\s*)([\"'])", [.group(1), .group(3), .group(5)])
        if !apply("(\(cjk))([({\\[]+(.*?)[)}\\]]+)(\(cjk))", [.group(1), .space, .group(2), .space, .group(4)]) {
            apply("(\(cjk))([(){}\\[\\]<>])", [.group(1), .space, .group(2)])
            apply("([(){}\\[\\]<>])(\(cjk))", [.group(1), .space, .group(2)])
        }
        apply("([({\\[)]+)(\\s*)(.+?)(\\s*)([)}\\]]+)", [.group(1), .group(3), .group(5)])
        apply("(\(cjk))(#(\\S+))", [.group(1), .space, .group(2)])
        apply("((\\S+)#)(\(cjk))", [.group(1), .space, .group(3)])
        apply("(\(cjk))([a-z0-9`~@$%^&*\\-_+=|\\\\/])", [.group(1), .space, .group(2)], options: .caseInsensitive)
        apply("([a-z0-9`~!$%^&*\\-_+=|\\\\;:,./?])(\(cjk))", [.group(1), .space, .group(2)], options: .caseInsensitive)
        result.removeAttribute(protectedKey, range: NSRange(location: 0, length: result.length))
        return result
    }
}
