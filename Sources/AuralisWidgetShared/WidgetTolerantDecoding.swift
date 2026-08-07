import Foundation

/// A scalar JSON number that also accepts numeric strings. Non-finite values
/// are decoded so the owning model can apply its own deterministic fallback.
public struct TolerantDouble: Decodable {
    public let value: Double

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
            return
        }
        if let string = try? container.decode(String.self), let number = Double(string) {
            value = number
            return
        }
        throw DecodingError.typeMismatch(
            Double.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a number or numeric string"
            )
        )
    }
}

/// Preserves array positions while replacing malformed numeric entries with
/// zero. This matters for EQ data, where skipping one value would shift every
/// subsequent frequency band.
public struct TolerantDoubleArray: Decodable {
    public let values: [Double]

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Double] = []
        while !container.isAtEnd {
            let startingIndex = container.currentIndex
            if let value = try? container.decode(TolerantDouble.self).value {
                values.append(value)
            } else {
                if container.currentIndex == startingIndex {
                    _ = try? container.decode(DiscardedJSONValue.self)
                }
                values.append(0)
            }
        }
        self.values = values
    }
}

/// Lossy collection decoding used for persisted identity lists and widget
/// snapshots. A malformed element cannot make otherwise recoverable data
/// unreadable.
public struct TolerantArray<Element: Decodable>: Decodable {
    public let values: [Element]

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Element] = []
        while !container.isAtEnd {
            let startingIndex = container.currentIndex
            if let value = try? container.decode(Element.self) {
                values.append(value)
            } else if container.currentIndex == startingIndex {
                _ = try? container.decode(DiscardedJSONValue.self)
            }
        }
        self.values = values
    }
}

public struct DynamicCodingKey: CodingKey {
    public let stringValue: String
    public let intValue: Int?

    public init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    public init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Recursively consumes one unknown JSON value after a typed decode fails.
public struct DiscardedJSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            while !array.isAtEnd {
                _ = try? array.decode(DiscardedJSONValue.self)
            }
            return
        }

        if let object = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            for key in object.allKeys {
                _ = try? object.decode(DiscardedJSONValue.self, forKey: key)
            }
            return
        }

        let value = try decoder.singleValueContainer()
        if value.decodeNil() { return }
        if (try? value.decode(Bool.self)) != nil { return }
        if (try? value.decode(Double.self)) != nil { return }
        if (try? value.decode(String.self)) != nil { return }
        throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unsupported JSON value")
    }
}

public extension KeyedDecodingContainer {
    func tolerant<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }

    func tolerantDouble(forKey key: Key) -> Double? {
        tolerant(TolerantDouble.self, forKey: key)?.value
    }
}

enum WidgetWireNormalization {
    static let bandCount = 10

    static func unit(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, 0), 1)
    }

    static func gainRange(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 12 }
        return min(value, 24)
    }

    static func gains(_ values: [Double], range: Double) -> [Double] {
        let sized = Array(values.prefix(bandCount))
            + Array(repeating: 0, count: max(bandCount - values.count, 0))
        return sized.map { value in
            guard value.isFinite else { return 0 }
            return min(max(value, -range), range)
        }
    }

    static func identity(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    static func optionalIdentity(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
