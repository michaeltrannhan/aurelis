import Foundation

enum CoreAudioBiquadMath {
    static let graphicEQQ: Double = 1.4
    private static let maximumAbsoluteGainDB = 60.0
    private static let minimumQ = 0.05
    private static let maximumQ = 100.0
    private static let coefficientMagnitudeLimit = 64.0
    static let frequencies: [Double] = [
        31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]
    static let unityCoefficients: [Double] = [1, 0, 0, 0, 0]

    static func peakingEQCoefficients(
        frequency: Double,
        gainDB: Double,
        q: Double,
        sampleRate: Double
    ) -> [Double] {
        guard frequency.isFinite,
              gainDB.isFinite,
              q.isFinite,
              sampleRate.isFinite,
              frequency > 0,
              abs(gainDB) <= maximumAbsoluteGainDB,
              (minimumQ...maximumQ).contains(q),
              (CoreAudioPCMFormat.minimumSampleRate...CoreAudioPCMFormat.maximumSampleRate)
                .contains(sampleRate),
              frequency < sampleRate / 2 else {
            return unityCoefficients
        }

        // A zero-gain peaking filter is mathematically transparent, but the
        // cookbook coefficients are not the literal unity tuple. Returning
        // unity here lets the render path omit untouched EQ bands entirely.
        guard abs(gainDB) >= 0.0001 else { return unityCoefficients }

        let amplitude = pow(10, gainDB / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let sine = sin(omega)
        let cosine = cos(omega)
        let alpha = sine / (2 * q)

        let b0 = 1 + alpha * amplitude
        let b1 = -2 * cosine
        let b2 = 1 - alpha * amplitude
        let a0 = 1 + alpha / amplitude
        let a1 = -2 * cosine
        let a2 = 1 - alpha / amplitude

        guard amplitude.isFinite,
              a0.isFinite,
              abs(a0) > Double.leastNormalMagnitude else {
            return unityCoefficients
        }
        let coefficients = [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
        guard coefficients.allSatisfy({
            $0.isFinite && abs($0) <= coefficientMagnitudeLimit
        }) else {
            return unityCoefficients
        }
        return coefficients
    }

    static func coefficientsForEQCurve(_ curve: EQCurve, sampleRate: Double) -> [Double] {
        guard sampleRate.isFinite,
              (CoreAudioPCMFormat.minimumSampleRate...CoreAudioPCMFormat.maximumSampleRate)
                .contains(sampleRate) else {
            return unityCoefficientsForSections(EQCurve.bandCount)
        }
        let normalized = EQCurve.normalized(curve.gains, range: curve.range)
        return frequencies.enumerated().flatMap { index, frequency in
            peakingEQCoefficients(
                frequency: frequency,
                gainDB: normalized[index],
                q: graphicEQQ,
                sampleRate: sampleRate
            )
        }
    }

    static func unityCoefficientsForSections(_ sectionCount: Int) -> [Double] {
        guard sectionCount > 0 else { return [] }
        return (0..<sectionCount).flatMap { _ in unityCoefficients }
    }

    static func isFlat(_ curve: EQCurve) -> Bool {
        EQCurve.normalized(curve.gains, range: curve.range).allSatisfy { abs($0) < 0.0001 }
    }
}
