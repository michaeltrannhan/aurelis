import OSLog

enum WidgetDiagnostics {
    private static let logger = Logger(subsystem: "com.michaeltrannhan.Auralis", category: "widget-extension")

    static func record(_ message: String) {
        #if DEBUG
        // The debug runner streams at info level to avoid macOS dropping the
        // firehose of unrelated system debug events. Keep widget interaction
        // breadcrumbs visible in that focused session log.
        logger.notice("\(message, privacy: .public)")
        #endif
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
