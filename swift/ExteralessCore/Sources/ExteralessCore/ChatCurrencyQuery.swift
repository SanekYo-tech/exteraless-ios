import Foundation

public enum ChatCurrencyQuery {
    private static let words: Set<String> = {
        var words = Set(Locale.isoCurrencyCodes.map { $0.lowercased() })
        words.formUnion("usd eur rub uah kzt byn gbp jpy cny try inr brl cad aud chf pln czk sek nok dkk huf ron bgn gel amd azn uzs kgs tjs mdl ils aed sar krw hkd sgd thb vnd idr myr php mxn ars clp cop pen nzd zar egp rsd isk ton gram btc eth usdt usdc sol bnb trx ltc xrp doge not dogs ada shib dot xmr xtr xtrf kr kč zł lei".split(separator: " ").map(String.init))
        let aliases = [
            "дол", "длр", "доллар(а/ов/ы/ах/е)", "бакс(а/ов/ы/ах)", "юсд", "dollar", "dollars", "buck", "bucks",
            "долар(а/ів/и/ах)", "баксів", "бакси", "евр", "евро", "euro", "euros", "євро", "quid", "руб", "рубль",
            "рубл(я/ей/и/ях)", "ruble", "rubles", "рублів", "рублі", "rur", "р", "грн", "гривн(а/ы/ах/е/у)", "гривен",
            "hryvnia", "hryvnias", "грив(ня/ні/ень/нях/ню)", "зл", "zl", "злот(ый/ых/ые)", "zloty", "zlotys", "злот(ий/их/і)",
            "лари", "lari", "ларі", "драм(а/ов/ы/ах)", "dram", "drams", "драмів", "драми", "йена", "йены", "йен", "йенах", "йену", "yen",
            "єна", "єни", "єн", "єнах", "єну", "юань", "юан(я/ей/и/ях)", "жэньминьби", "женьминьби", "yuan", "yuans", "rmb", "renminbi", "renminbis", "юанів", "юані", "женьміньбі",
            "вон(а/ов/ы/ах)", "won", "тенге", "tenge", "теньге", "тг", "бун(а/ов/ы/ах)", "бунів", "буни", "byr", "лир(а/ы/ах/у)", "лир", "ліра", "лірах", "ліри", "лір", "ліру", "tl", "lira", "liras",
            "сом(а/ов/ы/ах)", "som", "soms", "сомів", "соми", "сум(а/ов/ы/ах)", "сумів", "суми", "fcfa", "тугрик(а/ов/и/ах)", "tugrik", "tugriks", "тугриків",
            "бат(а/ов/ы/ах)", "baht", "bahts", "батів", "бати", "франк(а/ов/ы/ах)", "franc", "francs", "франків", "форинт(а/ов/ы/ах)", "forint", "forints", "форинтів", "форинти",
            "шекель", "шекел(я/ей/и/ях)", "shekel", "shekels", "шекелів", "шекелі", "nis", "дирхам(а/ов/ы/ах)", "dirham", "dirhams", "дирхамів", "дирхами", "dh", "dhs",
            "рупи(я/и/й/ях/ю)", "рупі(я/ї/й/ях/ю)", "rupee", "rupees", "rs", "лей", "лея", "леев", "леи", "леях", "леї", "леїв", "leu",
            "реал(а/ов/ы/ах)", "реали", "реалів", "real", "reais", "kc", "донг(а/ов/и/ах)", "dong", "dongs", "донгів", "манат(а/ов/ы/ах)", "manat", "manats", "манатів", "манати",
            "рэнд(а/ов/ы/ах)", "rand", "rands", "ранд(а/ів/и/ах)", "така", "taka", "найра", "naira", "стар(с/а/са/ов/сов/сы/сах)", "star", "stars",
            "звезд(а/ы/ах/у)", "звёзд(ы/ах)", "зірк(а/и/у/ою/ам/ами/ах)", "зірці", "зірок", "тон(а/ов/ы/ах/е)", "ton", "tons", "grams", "грам(а/ов/ы/ах/е)", "тонів", "тони", "грамів", "грами", "toncoin(s)",
            "тонкоин(а/ов/ы/ах/е)", "тонкоїн(а/ів/и/ах)", "бтк", "биток", "биткоин(а/ов/ы/ах/е)", "битк(а/ов/и/ах)", "bitcoin", "bitcoins", "btc", "біткоїн(а/ів/и/ах)", "биткойн(а/ов/ы/ах/е)", "біткойн(а/ів/и/ах)",
            "эфир(а/ов/ы/ах/е)", "ethereum", "ethereums", "eth", "ефір(у/ів/и/ах)", "эфириум(а/ов/ы/ах/е)", "ефіріум(у/ів/и/ах)", "бнб", "бинанс(а/ов/ы/ах/е)", "binance", "binances", "bnb", "бінанс(а/ів/и/ах)",
            "рипл(а/ов/ы/ах/е)", "ripple", "ripples", "xrp", "хрп", "риплів", "рипли", "кардан(о/а/ов/ы/ах/е)", "cardano", "cardanos", "ада", "ada", "доги", "доге", "dogecoin", "dogecoins", "doge",
            "юсдт", "tether", "тезер(а/ов/ы/ах/ів/и)", "солана", "соланы", "солан", "солане", "соланах", "соль", "соли", "солей", "солях", "солью", "solana", "солани", "сол",
            "лайткоин(а/ов/ы/ах/е)", "лайт", "litecoin", "litecoins", "ltc", "лайткоїн(а/ів/и/ах)", "трон(а/ов/ы/ах/е)", "tron", "trx", "тронів", "трони", "шиба", "шибы", "шиб", "шибах", "шибе", "shiba", "shib", "шиби",
            "полкадот(а/ов/ы/ах/е)", "дот", "polkadot", "полкадотів", "полкадоти", "хмр", "монеро", "monero", "sat", "sats", "satoshi", "satoshis", "сатоши", "сатоші", "gwei", "гвей", "гвеи", "гвеев", "гвеях", "гвеї", "гвеїв", "wei", "nanoton", "nanotons", "нанотон(а/ов/ы/ах)", "нанотонів", "нанотони"
        ]
        for alias in aliases {
            if let open = alias.firstIndex(of: "(") {
                let base = String(alias[..<open])
                words.insert(base)
                for suffix in alias[alias.index(after: open)...].dropLast().split(separator: "/") { words.insert(base + String(suffix)) }
            } else {
                words.insert(alias)
            }
        }
        return words
    }()

    public static func query(in text: String, caret: Int) -> String? {
        let source = Array(text.utf16)
        guard caret > 0, caret <= source.count, source[caret - 1] == 61 else { return nil }
        var after = caret
        while after < source.count && blank(source[after]) { after += 1 }
        if after < source.count && (digit(source[after]) || source[after] == 46 || source[after] == 44) { return nil }
        let end = caret - 1
        let limit = max(0, end - 64)
        var start = end
        while start > limit && queryCharacter(source[start - 1]) { start -= 1 }
        if start > 0 && (letter(source[start - 1]) || digit(source[start - 1]) || source[start - 1] == 95) { return nil }
        while start < end {
            while start < end && blank(source[start]) { start += 1 }
            guard start < end else { return nil }
            let candidate = String(decoding: source[start ..< end], as: UTF16.self).trimmingCharacters(in: .whitespaces)
            if (digit(source[start]) || currency(source[start])) && mentionsCurrency(candidate) { return candidate }
            while start < end && !blank(source[start]) && source[start] != 40 { start += 1 }
            start += 1
        }
        return nil
    }

    public static func result(title: String?) -> String? {
        guard let title, title.hasPrefix("=") else { return nil }
        let result = title.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !result.isEmpty, result.utf16.count <= 128, !result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return result
    }

    private static func blank(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 160 }
    private static func digit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private static func letter(_ c: UInt16) -> Bool { UnicodeScalar(UInt32(c)).map { CharacterSet.letters.contains($0) } ?? false }
    private static func currency(_ c: UInt16) -> Bool { c == 9733 || (UnicodeScalar(UInt32(c)).map { $0.properties.generalCategory == .currencySymbol } ?? false) }
    private static func queryCharacter(_ c: UInt16) -> Bool {
        letter(c) || digit(c) || currency(c) || blank(c) || [46, 44, 43, 45, 8722, 42, 215, 47, 247, 94, 37, 33, 8730, 40, 41, 59].contains(c)
    }
    private static func mentionsCurrency(_ query: String) -> Bool {
        let source = Array(query.utf16)
        guard source.contains(where: digit) else { return false }
        if source.contains(where: currency) { return true }
        let tokens = query.lowercased().split { !$0.isLetter }
        return tokens.contains { words.contains(String($0)) || words.contains(String($0).replacingOccurrences(of: "i", with: "і")) }
    }
}

/// Main-thread native adapter uses this generation to discard old-account/old-caret completions.
public struct ChatCurrencyRequestState: Sendable {
    public private(set) var query: String?
    public private(set) var generation: UInt64 = 0
    public init() {}
    public mutating func begin(query: String) -> UInt64? {
        guard self.query != query else { return nil }
        self.generation &+= 1
        self.query = query
        return self.generation
    }
    public mutating func complete(query: String, generation: UInt64) -> Bool {
        guard self.query == query, self.generation == generation else { return false }
        self.query = nil
        return true
    }
    public mutating func cancel() { self.generation &+= 1; self.query = nil }
}
