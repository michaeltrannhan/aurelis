import Foundation

/// A scalar JSON number that also accepts numeric strings. Non-finite values
/// are decoded so the owning model can apply its own deterministic fallback.
struct TolerantDouble: Decodable {
    let value: Double

    init(from decoder: Decoder) throws {
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
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a number or numeric string")
        )
    }
}

/// Preserves array positions while replacing malformed numeric entries with
/// zero. This matters for EQ data, where skipping one value would shift every
/// subsequent frequency band.
struct TolerantDoubleArray: Decodable {
    let values: [Double]

    init(from decoder: Decoder) throws {
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

/// Lossy collection decoding used for persisted identity lists. A malformed
/// element cannot make otherwise recoverable settings unreadable.
struct TolerantArray<Element: Decodable>: Decodable {
    let values: [Element]

    init(from decoder: Decoder) throws {
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

struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Recursively consumes one unknown JSON value after a typed decode fails.
struct DiscardedJSONValue: Decodable {
    init(from decoder: Decoder) throws {
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

extension KeyedDecodingContainer {
    func tolerant<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }

    func tolerantDouble(forKey key: Key) -> Double? {
        tolerant(TolerantDouble.self, forKey: key)?.value
    }
}
