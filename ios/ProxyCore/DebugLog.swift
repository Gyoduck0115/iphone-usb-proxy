import Darwin
import Foundation

/// Masks public IPv4/IPv6 addresses in diagnostic logs while keeping loopback and RFC1918/private
/// ranges intact for debugging. Adapted from `viktor-svirsky/tether`'s `LogRedaction.swift`.
public enum LogRedaction {
    public static let lineLimit = 500

    private static let ipv4Regex = try! NSRegularExpression(
        pattern: "(?<![0-9.])(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})(?![0-9])"
    )
    private static let ipv6RunRegex = try! NSRegularExpression(
        pattern: "[0-9A-Fa-f:.]*:[0-9A-Fa-f.]*:[0-9A-Fa-f:.]*"
    )

    public static func redact(_ line: String) -> String {
        var s = line
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        s = replace(ipv6RunRegex, in: s, with: shortenIPv6)
        s = replace(ipv4Regex, in: s, with: shortenIPv4)
        if s.count > lineLimit {
            s = String(s.prefix(lineLimit - 1)) + "…"
        }
        return s
    }

    private static func replace(
        _ regex: NSRegularExpression,
        in s: String,
        with transform: (String) -> String
    ) -> String {
        let ns = s as NSString
        var out = ""
        var offset = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: offset, length: match.range.location - offset))
            out += transform(ns.substring(with: match.range))
            offset = match.range.location + match.range.length
        }
        return out + ns.substring(from: offset)
    }

    private static func shortenIPv4(_ text: String) -> String {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 >= 0 && $0 <= 255 }), isPublicIPv4(parts) else {
            return text
        }
        return "\(parts[0]).\(parts[1]).…"
    }

    private static func isPublicIPv4(_ n: [Int]) -> Bool {
        switch (n[0], n[1], n[2]) {
        case (0, _, _), (10, _, _), (127, _, _), (224..., _, _): return false
        case (100, 64...127, _), (169, 254, _), (172, 16...31, _), (192, 168, _): return false
        case (198, 18...19, _): return false // dummy tunnel RFC 2544 range
        case (192, 0, 2), (198, 51, 100), (203, 0, 113): return false
        default: return true
        }
    }

    private static func shortenIPv6(_ run: String) -> String {
        guard run != "::1", run != "::" else { return run }
        var addr = in6_addr()
        guard inet_pton(AF_INET6, run, &addr) == 1 else { return run }
        let groups: [UInt16] = withUnsafeBytes(of: &addr) { bytes in
            stride(from: 0, to: 16, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
        }
        return "\(String(groups[0], radix: 16)):\(String(groups[1], radix: 16)):…"
    }
}

/// Rotating two-segment file logger (`current.log` + `previous.log`, max ~512 KB on disk) with
/// automatic redaction, modeled after `viktor-svirsky/tether`'s `DebugLog.swift`.
public final class DebugLog: @unchecked Sendable {
    public static let defaultSegmentLimit = 256 * 1024

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("USBProxyLog", isDirectory: true)
    }

    private let directory: URL
    private let segmentLimit: Int
    private let timeZone: TimeZone
    private let now: () -> Date
    private let formatter: DateFormatter
    private let lock = NSLock()
    private var recentLines: [String] = []
    private let maxRecentLines = 120

    private var currentURL: URL { directory.appendingPathComponent("current.log") }
    private var previousURL: URL { directory.appendingPathComponent("previous.log") }

    public init(
        directory: URL = DebugLog.defaultDirectory,
        segmentLimit: Int = DebugLog.defaultSegmentLimit,
        timeZone: TimeZone = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.segmentLimit = segmentLimit
        self.timeZone = timeZone
        self.now = now
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = timeZone
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.formatter = df
    }

    public func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let redacted = LogRedaction.redact(text)
        let formatted = "\(formatter.string(from: now())) \(redacted)"
        recentLines.append(formatted)
        if recentLines.count > maxRecentLines {
            recentLines.removeFirst(recentLines.count - maxRecentLines)
        }
        writeLocked(formatted + "\n")
    }

    public func recent() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recentLines
    }

    public func export(header: String = "") -> String {
        lock.lock()
        defer { lock.unlock() }
        let body = [previousURL, currentURL]
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined()
        var out = header.isEmpty ? "" : header + "\n"
        out += "TimeZone: \(timeZone.identifier)\n\n"
        out += body.isEmpty ? "No log entries yet.\n" : body
        return out
    }

    public func writeExport(header: String, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("USBProxy-log.txt")
        try export(header: header).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeLocked(_ line: String) {
        let data = Data(line.utf8)
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let size = (try? fm.attributesOfItem(atPath: currentURL.path)[.size] as? Int) ?? 0
            if size > 0, size + data.count > segmentLimit {
                try? fm.removeItem(at: previousURL)
                try fm.moveItem(at: currentURL, to: previousURL)
            }
            if !fm.fileExists(atPath: currentURL.path) {
                try Data().write(to: currentURL)
            }
            let handle = try FileHandle(forWritingTo: currentURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Logging must never crash the proxy or extension.
        }
    }
}
