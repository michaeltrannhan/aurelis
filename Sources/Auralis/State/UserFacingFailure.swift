import Foundation

/// Concise copy safe for UI and public logs. Technical detail stays private.
struct UserFacingFailure: Equatable, Sendable, LocalizedError {
    let title: String
    let message: String
    /// Private diagnostics never shown in UI or public logs.
    let technicalDetail: String?

    var errorDescription: String? { message }

    init(title: String, message: String, technicalDetail: String? = nil) {
        self.title = Self.redact(title)
        self.message = Self.redact(message)
        self.technicalDetail = technicalDetail.map(Self.redactTechnical)
    }

    static func from(_ error: Error, title: String = "Something went wrong") -> UserFacingFailure {
        if let failure = error as? UserFacingFailure { return failure }
        let raw = error.localizedDescription
        return UserFacingFailure(
            title: title,
            message: sanitizePublicMessage(raw),
            technicalDetail: raw
        )
    }

    static func sanitizePublicMessage(_ raw: String) -> String {
        let redacted = redact(raw)
        if redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The operation could not be completed."
        }
        return redacted
    }

    /// Strip OSStatus codes, selectors, App Group IDs, and local paths.
    static func redact(_ text: String) -> String {
        var result = text
        let patterns: [(String, String)] = [
            (#"OSStatus\s*=?\s*-?\d+"#, "an audio system error"),
            (#"\berr\s*=?\s*-?\d{3,}\b"#, "an audio system error"),
            (#"\bstatus\s*=?\s*-?\d{3,}\b"#, "an audio system error"),
            (#"\bselector\s*[:=]\s*\S+"#, "a system selector"),
            (#"\bgroup\.[A-Za-z0-9._-]+"#, "the shared container"),
            (#"\b[A-Z0-9]{10}\.com\.[A-Za-z0-9._-]+"#, "the shared container"),
            (#"/(?:Users|var|private|tmp)/[^\s\"']+"#, "a local path"),
            (#"file://[^\s\"']+"#, "a local path"),
            (#"~/[^\s\"']+"#, "a local path"),
        ]
        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: range,
                    withTemplate: replacement
                )
            }
        }
        return result
    }

    private static func redactTechnical(_ text: String) -> String {
        // Keep technical detail for internal diagnostics, but still drop home paths
        // that could leak into exported redacted logs.
        redact(text)
    }
}
