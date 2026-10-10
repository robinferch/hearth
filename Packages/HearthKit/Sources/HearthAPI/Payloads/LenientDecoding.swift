import Foundation

// audiobookshelf responses vary between server versions: numbers are sometimes strings, arrays are sometimes
// single objects and many fields are missing or `null`. These helpers never throw for a malformed optional
// field; they return `nil` / empty values instead so one odd field cannot break a whole list.

/// A coding key built from an arbitrary string.
struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        stringValue = string
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Decodes an element if possible and records `nil` otherwise (used for lossy arrays).
struct Failable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// A JSON value that is either a single element or an array of elements.
struct OneOrMany<T: Decodable>: Decodable {
    let values: [T]

    init(from decoder: any Decoder) throws {
        if let array = try? [Failable<T>](from: decoder) {
            values = array.compactMap(\.value)
        } else if let single = try? T(from: decoder) {
            values = [single]
        } else {
            values = []
        }
    }
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    func string(_ key: String) -> String? {
        let key = AnyCodingKey(key)
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    /// Non-empty string, otherwise `nil`.
    func nonEmptyString(_ key: String) -> String? {
        guard let value = string(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    func double(_ key: String) -> Double? {
        let key = AnyCodingKey(key)
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value.isFinite ? value : nil
        }
        if let string = try? decodeIfPresent(String.self, forKey: key), let value = Double(string.trimmingCharacters(in: .whitespaces)) {
            return value.isFinite ? value : nil
        }
        return nil
    }

    func int(_ key: String) -> Int? {
        guard let value = double(key) else { return nil }
        return Int(exactly: value.rounded(.towardZero))
    }

    func int64(_ key: String) -> Int64? {
        guard let value = double(key) else { return nil }
        return Int64(exactly: value.rounded(.towardZero))
    }

    func bool(_ key: String) -> Bool? {
        let key = AnyCodingKey(key)
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            switch string.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no", "": return false
            default: return nil
            }
        }
        return nil
    }

    /// Epoch milliseconds → `Date`.
    func dateMS(_ key: String) -> Date? {
        guard let value = double(key), value > 0 else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }

    func decode<T: Decodable>(_ key: String, as type: T.Type = T.self) -> T? {
        try? decodeIfPresent(T.self, forKey: AnyCodingKey(key))
    }

    /// Array that skips undecodable elements; accepts a single object as a one-element array.
    func array<T: Decodable>(_ key: String, of type: T.Type = T.self) -> [T] {
        (try? decodeIfPresent(OneOrMany<T>.self, forKey: AnyCodingKey(key)))?.values ?? []
    }

    /// String array that also accepts numbers and drops empty values.
    func strings(_ key: String) -> [String] {
        array(key, of: LenientString.self).map(\.value).filter { !$0.isEmpty }
    }

    func contains(_ key: String) -> Bool {
        contains(AnyCodingKey(key))
    }
}

/// A string that may be encoded as a number.
struct LenientString: Decodable, Hashable {
    let value: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int64.self) {
            value = String(int)
        } else {
            value = String(try container.decode(Double.self))
        }
    }
}

extension Decoder {
    func lenient() throws -> KeyedDecodingContainer<AnyCodingKey> {
        try container(keyedBy: AnyCodingKey.self)
    }
}

extension JSONDecoder {
    static var api: JSONDecoder { JSONDecoder() }
}
