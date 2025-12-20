import Foundation
import os

let logger: Logger? = Logger(subsystem: "TODO", category: "TODO")

nonisolated
func timeit<R>(_ label: String? = nil, _ action: () throws -> R) rethrows -> R {
    let start = CFAbsoluteTimeGetCurrent()
    defer {
        let end = CFAbsoluteTimeGetCurrent()

        let duration = end - start
        Task { @MainActor in
            logger?.info("⏱️ \(label ?? "Operation") took \(duration * 1_000) msec")
        }
    }
    return try action()
}
