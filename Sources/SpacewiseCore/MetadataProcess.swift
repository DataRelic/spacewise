import Darwin
import Foundation

/// Why a metadata tool run produced no usable output. Carries the underlying error where there is one.
enum MetadataToolError: Error, CustomStringConvertible {
    case cancelled
    case deadlineExceeded
    case invalidLimit(Int)
    case pipeSetupFailed(errno: Int32)
    case spawnFailed(executable: String, underlying: any Error)
    case outputLimitExceeded(limit: Int)
    case readFailed(errno: Int32)
    case nonzeroExit(status: Int32)
    case malformedOutput(underlying: (any Error)?)

    var isCancellation: Bool { if case .cancelled = self { true } else { false } }
    /// A fixed name for logs. Unlike `description`, it never includes the executable path or an underlying error.
    var logCode: String {
        switch self {
        case .cancelled: "cancelled"
        case .deadlineExceeded: "deadlineExceeded"
        case .invalidLimit: "invalidLimit"
        case .pipeSetupFailed: "pipeSetupFailed"
        case .spawnFailed: "spawnFailed"
        case .outputLimitExceeded: "outputLimitExceeded"
        case .readFailed: "readFailed"
        case .nonzeroExit: "nonzeroExit"
        case .malformedOutput: "malformedOutput"
        }
    }
    /// The number that goes with `logCode` (errno, exit status or byte limit), or -1 when there is none.
    var logValue: Int64 {
        switch self {
        case .invalidLimit(let limit), .outputLimitExceeded(let limit): Int64(limit)
        case .pipeSetupFailed(let code), .readFailed(let code): Int64(code)
        case .nonzeroExit(let status): Int64(status)
        case .cancelled, .deadlineExceeded, .spawnFailed, .malformedOutput: -1
        }
    }
    var description: String {
        switch self {
        case .cancelled: "cancelled"
        case .deadlineExceeded: "deadline exceeded"
        case .invalidLimit(let limit): "invalid output limit \(limit)"
        case .pipeSetupFailed(let code): "output pipe setup failed, errno \(code)"
        case .spawnFailed(let executable, let underlying):
            "could not start \(executable): \(underlying.localizedDescription)"
        case .outputLimitExceeded(let limit): "output exceeded \(limit) bytes"
        case .readFailed(let code): "reading output failed, errno \(code)"
        case .nonzeroExit(let status): "exited with status \(status)"
        case .malformedOutput(let underlying):
            "output was not a property list" + (underlying.map { ": \($0.localizedDescription)" } ?? "")
        }
    }
}

/// Synchronous worker-only bridge. Nonblocking reads bound memory and keep cancellation observable.
/// Owns exactly one child; SIGKILL is confined to that child's PID and Foundation reaps it.
enum BoundedMetadataProcess {
    static func run(
        executable: String = "/usr/sbin/diskutil", arguments: [String],
        deadline: Date = Date().addingTimeInterval(5),
        limit: Int = 2_097_152
    ) throws(MetadataToolError) -> Data {
        guard limit > 0 else { throw .invalidLimit(limit) }
        guard !Task.isCancelled else { throw .cancelled }
        guard Date() < deadline else { throw .deadlineExceeded }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let fd = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { throw .pipeSetupFailed(errno: errno) }
        do { try process.run() } catch { throw .spawnFailed(executable: executable, underlying: error) }
        // The parent's write end must close so the read side sees EOF; the child holds its own copy.
        // A failed close only leaks a descriptor until the pipe is released, and cannot change what was read.
        try? pipe.fileHandleForWriting.close()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            // Best-effort cleanup after the output has been read or abandoned; there is nothing left to act on.
            try? pipe.fileHandleForReading.close()
        }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            guard !Task.isCancelled else { throw .cancelled }
            guard Date() < deadline else { throw .deadlineExceeded }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                guard count <= limit - output.count else { throw .outputLimitExceeded(limit: limit) }
                output.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                if !process.isRunning {
                    guard process.terminationStatus == 0 else { throw .nonzeroExit(status: process.terminationStatus) }
                    return output
                }
            } else if errno != EAGAIN && errno != EINTR {
                throw .readFailed(errno: errno)
            }
            if count <= 0 { Thread.sleep(forTimeInterval: 0.005) }
        }
    }
}
