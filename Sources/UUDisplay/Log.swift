// 线程安全日志：同时输出到 stdout 和 ~/Library/Logs/UUDisplay.log，支持 1MB 自动轮转、POSIX O_APPEND 原子追加与连续重复行折叠
import Darwin
import Foundation

enum Log {
    static var writeToFile = true
    static let fileURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/UUDisplay.log")
    private static let backupURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/UUDisplay.log.1")
    private static let maxBytes: UInt64 = 1_048_576  // 1 MB
    private static let queue = DispatchQueue(label: "uudisplay.log")
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static var lastMessage: String?
    private static var repeatCount = 0

    static func info(_ msg: String) {
        queue.sync {
            if msg == lastMessage {
                repeatCount += 1
                if repeatCount <= 2 {
                    emit(msg)
                }
                return
            }
            if repeatCount > 2 {
                emit("↳ 上一条日志重复省略 \(repeatCount - 2) 次")
            }
            lastMessage = msg
            repeatCount = 1
            emit(msg)
        }
    }

    static func flushRepeatSummary() {
        queue.sync {
            if repeatCount > 2 {
                emit("↳ 上一条日志重复省略 \(repeatCount - 2) 次")
            }
            lastMessage = nil
            repeatCount = 0
        }
    }

    private static func emit(_ msg: String) {
        let line = "[\(fmt.string(from: Date()))] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
        guard writeToFile else { return }
        rotateIfNeeded()
        appendData(data)
    }

    private static func appendData(_ data: Data) {
        let flags = O_WRONLY | O_CREAT | O_APPEND
        let mode = mode_t(0o644)
        var fd = Darwin.open(fileURL.path, flags, mode)
        if fd < 0 {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            fd = Darwin.open(fileURL.path, flags, mode)
        }
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if n > 0 {
                    written += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64,
              size >= maxBytes else { return }
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: fileURL, to: backupURL)
    }
}
