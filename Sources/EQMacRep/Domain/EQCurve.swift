import Foundation

enum EQGainRange: Double, CaseIterable, Codable, Identifiable {
    case db6 = 6
    case db12 = 12
    case db18 = 18

    var id: Double { rawValue }

    var label: String {
        "\(Int(rawValue)) dB"
    }
}

struct EQCurve: Codable, Equatable {
    static let bandCount = 10
    static let frequencies = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var gains: [Double]
    var range: EQGainRange

    init(gains: [Double] = Array(repeating: 0, count: bandCount), range: EQGainRange = .db12) {
        self.range = range
        self.gains = Self.normalized(gains, range: range)
    }

    mutating func setGain(_ gain: Double, at index: Int) {
        guard gains.indices.contains(index) else { return }
        gains[index] = Self.clamped(gain, range: range)
    }

    mutating func applyRange(_ newRange: EQGainRange) {
        range = newRange
        gains = Self.normalized(gains, range: newRange)
    }

    mutating func reset() {
        gains = Array(repeating: 0, count: Self.bandCount)
    }

    static func normalized(_ input: [Double], range: EQGainRange) -> [Double] {
        let sized: [Double]
        if input.count >= bandCount {
            sized = Array(input.prefix(bandCount))
        } else {
            sized = input + Array(repeating: 0, count: bandCount - input.count)
        }
        return sized.map { clamped($0, range: range) }
    }

    static func clamped(_ value: Double, range: EQGainRange) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -range.rawValue), range.rawValue)
    }
}
