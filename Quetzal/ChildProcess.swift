import Foundation

nonisolated enum ChildProcess {
    static func find(_ name: String) -> URL? {
        let manager = FileManager.default
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = path.split(separator: ":").map(String.init) + [
            manager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin"
        ]
        return dirs.lazy.filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: $0).appendingPathComponent(name)
        }.first(where: { isExecutable($0) })
    }

    static func isExecutable(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
    }

    static func readChunk(_ output: FileHandle, child: Process, queue: DispatchQueue) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 200)
                if ready == 0 {
                    // 子孫が stdout を継承していても、直接の子が終了したら読み取りを終える。
                    return continuation.resume(returning: child.isRunning ? Data() : nil)
                }
                if ready < 0 { return continuation.resume(returning: errno == EINTR ? Data() : nil) }
                var bytes = [UInt8](repeating: 0, count: 16384)
                let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
                if count < 0 && errno == EINTR { return continuation.resume(returning: Data()) }
                continuation.resume(returning: count > 0 ? Data(bytes.prefix(count)) : nil)
            }
        }
    }
}
