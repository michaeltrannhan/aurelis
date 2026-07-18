import Foundation

struct WidgetTolerantDouble: Decodable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let string = try? container.decode(String.self), let number = Double(string) {
            value = number
        } else {
            throw DecodingError.typeMismatch(
                Double.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a number")
            )
        }
    }
}

struct WidgetTolerantDoubleArray: Decodable {
    let values: [Double]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Double] = []
        while !container.isAtEnd {
            let index = container.currentIndex
            if let value = try? container.decode(WidgetTolerantDouble.self).value {
                result.append(value)
            } else {
                if container.currentIndex == index {
                    _ = try? container.decode(WidgetDiscardedJSONValue.self)
                }
                result.append(0)
            }
        }
        values = result
    }
}

struct WidgetTolerantArray<Element: Decodable>: Decodable {
    let values: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            let index = container.currentIndex
            if let value = try? container.decode(Element.self) {
                result.append(value)
            } else if container.currentIndex == index {
                _ = try? container.decode(WidgetDiscardedJSONValue.self)
            }
        }
        values = result
    }
}

private struct WidgetDynamicCodingKey: CodingKey {
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

struct WidgetDiscardedJSONValue: Decodable {
    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            while !array.isAtEnd { _ = try? array.decode(WidgetDiscardedJSONValue.self) }
            return
        }
        if let object = try? decoder.container(keyedBy: WidgetDynamicCodingKey.self) {
            for key in object.allKeys { _ = try? object.decode(WidgetDiscardedJSONValue.self, forKey: key) }
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
    func widgetTolerant<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }

    func widgetTolerantDouble(forKey key: Key) -> Double? {
        widgetTolerant(WidgetTolerantDouble.self, forKey: key)?.value
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
}
