import os.log

@MainActor
protocol ErrorLogging {
    func logError(_ message: String)
}

struct UnifiedErrorLogger: ErrorLogging {
    private let logger: Logger

    init(category: String) {
        logger = Logger(subsystem: "com.openwritr.app", category: category)
    }

    func logError(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
