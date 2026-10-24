import Foundation

struct ShellResult {
    var status: Int32
    var output: String
}

nonisolated func shell(_ command: String, in directory: URL? = nil) async -> ShellResult {
    await withCheckedContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            continuation.resume(returning: ShellResult(status: -1, output: error.localizedDescription))
            return
        }
        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            continuation.resume(returning: ShellResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
        }
    }
}

nonisolated func quoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
