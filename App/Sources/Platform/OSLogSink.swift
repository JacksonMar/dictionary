import Foundation
import os
import VocabCore

/// `LogSink` у unified logging. Повідомлення вже відредаговані `RedactingLogger`, тому `privacy: .public`.
struct OSLogSink: LogSink {
    static let subsystem = "com.vocabapp.VocabApp"

    private let logger: Logger

    init(category: String) {
        self.logger = Logger(subsystem: Self.subsystem, category: category)
    }

    func write(level: LogLevel, message: String) {
        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
    }
}
