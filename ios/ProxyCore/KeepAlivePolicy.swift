import Foundation

/// Pure Foundation policy for silent-audio background keep-alive and idle auto-stop.
/// Directly inspired by `viktor-svirsky/tether`'s `KeepAlivePolicy.swift` and `IdleStop.swift`,
/// kept UIKit-free so `swift test` validates every state transition on macOS.
public enum KeepAlivePolicy {
    public enum AudioEvent: Equatable, Sendable {
        /// A phone call, Siri, or alarm took the audio session.
        case interruptionBegan
        /// The interruption ended; iOS does not auto-resume silent background audio.
        case interruptionEnded
        /// iOS media server crashed or reset; the old player is dead and must be recreated.
        case mediaServicesLost
        /// iOS media server came back after a reset.
        case mediaServicesReset
    }

    public enum AudioRestart: Equatable, Sendable {
        /// Request background execution time and retry `play()` once per second until active.
        case holdOn
        /// Discard the dead player and rebuild the audio session immediately.
        case rebuild
    }

    /// Returns what recovery action `KeepAliveAudio` should take when an audio event fires.
    public static func restart(after event: AudioEvent, started: Bool) -> AudioRestart? {
        guard started else { return nil }
        switch event {
        case .interruptionBegan, .interruptionEnded, .mediaServicesLost:
            return .holdOn
        case .mediaServicesReset:
            return .rebuild
        }
    }

    /// Polling interval for status/health checks: faster on screen, slower in background to save battery.
    public static func watchInterval(sceneActive: Bool) -> TimeInterval {
        sceneActive ? 1.0 : 15.0
    }
}

/// Optional idle auto-stop timer for silent-audio background mode (prevents draining battery overnight
/// when the PC is disconnected). Inspired by `viktor-svirsky/tether`'s `IdleStop.swift`.
public struct IdleStopPolicy: Equatable, Sendable {
    public enum Timeout: Int, CaseIterable, Codable, Sendable {
        case never = 0
        case thirtyMinutes = 1800
        case oneHour = 3600
        case threeHours = 10800

        public var seconds: TimeInterval? {
            self == .never ? nil : TimeInterval(rawValue)
        }

        public var label: String {
            switch self {
            case .never: return "사용 안 함"
            case .thirtyMinutes: return "30분 유휴 시 중지"
            case .oneHour: return "1시간 유휴 시 중지"
            case .threeHours: return "3시간 유휴 시 중지"
            }
        }
    }

    private var idleSince: Date?

    public init() {}

    /// Returns `true` when the proxy should stop due to prolonged inactivity in the background.
    public mutating func check(
        running: Bool,
        activeConnections: Int,
        trafficChanged: Bool,
        sceneActive: Bool,
        timeout: Timeout,
        now: Date
    ) -> Bool {
        guard running, !sceneActive, activeConnections == 0, !trafficChanged else {
            idleSince = nil
            return false
        }
        let since = idleSince ?? now
        idleSince = since
        guard let limit = timeout.seconds, now.timeIntervalSince(since) >= limit else {
            return false
        }
        idleSince = nil
        return true
    }

    public mutating func reset() {
        idleSince = nil
    }
}
