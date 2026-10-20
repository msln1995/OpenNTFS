import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutString: String {
        String(decoding: stdout, as: UTF8.self)
    }

    public var stderrString: String {
        String(decoding: stderr, as: UTF8.self)
    }
}

public protocol CommandRunning: Sendable {
    func run(_ executable: String, arguments: [String]) throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        return try ProcessCapture.run(process)
    }
}

enum ProcessCapture {
    static func run(_ process: Process) throws -> CommandResult {
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()

        // Close the parent's write ends so reads receive EOF after the child exits.
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()

        let stdout = PipeBuffer()
        let stderr = PipeBuffer()
        let stdoutHandle = output.fileHandleForReading
        let stderrHandle = error.fileHandleForReading
        let group = DispatchGroup()

        // Draining only after waitUntilExit deadlocks once a child fills the pipe buffer.
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout.data = stdoutHandle.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr.data = stderrHandle.readDataToEndOfFile()
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        return CommandResult(
            status: process.terminationStatus,
            stdout: stdout.data,
            stderr: stderr.data
        )
    }
}

private final class PipeBuffer: @unchecked Sendable {
    var data = Data()
}
