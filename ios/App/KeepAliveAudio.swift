import AVFoundation
import UIKit

/// Plays a looping 8 kHz silent WAV so iOS keeps the app (and its 127.0.0.1:1080 listener) alive
/// in the background and while the screen is locked — even on a free Apple ID without Network Extension.
///
/// Directly adapted from `viktor-svirsky/tether/Sources/KeepAlive.swift`:
/// - Uses `.playback` with `.mixWithOthers` so music/podcasts keep playing uninterrupted.
/// - Uses a 0.5 s audio IO buffer to minimize CPU wakeups and battery drain.
/// - Survives phone calls, Siri, alarms, and iOS media server resets via a `UIBackgroundTaskIdentifier`
///   retry loop, notifying `onRecovered` so `ProxyServer` immediately verifies/reopens its listener.
@MainActor
final class KeepAliveAudio {
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lastFailure: String?
    private let log: (String) -> Void
    private let onRecovered: () -> Void

    init(log: @escaping (String) -> Void, onRecovered: @escaping () -> Void = {}) {
        self.log = log
        self.onRecovered = onRecovered
    }

    var isStarted: Bool { player != nil }
    var isSounding: Bool { player?.isPlaying == true }

    func start() {
        if player?.isPlaying == true {
            return
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        // Longest IO buffer iOS grants -> fewest CPU wakeups per second.
        try? session.setPreferredIOBufferDuration(0.5)
        do {
            try session.setActive(true)
            if player == nil {
                player = try AVAudioPlayer(data: Self.silentWav(seconds: 1))
                player?.numberOfLoops = -1
                player?.volume = 0
            }
            if player?.play() != true {
                throw PlayRefusedError()
            }
            lastFailure = nil
        } catch {
            let message = "keep-alive audio failed to start: \(error)"
            if message != lastFailure {
                log(message)
                lastFailure = message
            }
        }
        installObserversIfNeeded(session: session)
    }

    func stop() {
        player?.stop()
        player = nil
        endBackgroundHold()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func installObserversIfNeeded(session: AVAudioSession) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] note in
                let info = note.userInfo ?? [:]
                MainActor.assumeIsolated {
                    self?.handleInterruption(info)
                }
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereLostNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleAudioEvent(.mediaServicesLost)
                }
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleAudioEvent(.mediaServicesReset)
                }
            },
        ]
    }

    private func handleInterruption(_ info: [AnyHashable: Any]) {
        guard let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        switch type {
        case .began:
            log("audio keep-alive interrupted (call/Siri/alarm)")
            handleAudioEvent(.interruptionBegan)
        case .ended:
            log("audio interruption ended, resuming keep-alive")
            handleAudioEvent(.interruptionEnded)
        @unknown default:
            break
        }
    }

    private func handleAudioEvent(_ event: KeepAlivePolicy.AudioEvent) {
        switch KeepAlivePolicy.restart(after: event, started: isStarted) {
        case .holdOn:
            beginRetryHold(after: event)
        case .rebuild:
            player = nil
            start()
            log("media services reset, keep-alive sounding=\(isSounding)")
            endBackgroundHold()
            if isSounding { onRecovered() }
        case nil:
            break
        }
    }

    private func beginRetryHold(after event: KeepAlivePolicy.AudioEvent) {
        let mediaLost = (event == .mediaServicesLost)
        if mediaLost { player = nil }
        guard backgroundTask == .invalid else { return }

        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: mediaLost ? "USBProxyMediaReset" : "USBProxyAudioInterruption"
        ) { [weak self] in
            MainActor.assumeIsolated {
                if mediaLost { self?.player = nil }
                self?.log("background grace expired before keep-alive audio resumed")
                self?.endBackgroundHold()
            }
        }

        if backgroundTask == .invalid {
            start()
            if isSounding { onRecovered() }
        } else {
            retryPlayLoop(taskID: backgroundTask, attempt: 1)
        }
    }

    private func retryPlayLoop(taskID: UIBackgroundTaskIdentifier, attempt: Int) {
        guard backgroundTask == taskID else { return }
        start()
        if isSounding {
            log("audio keep-alive recovered after \(attempt) attempt(s)")
            endBackgroundHold()
            onRecovered()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            MainActor.assumeIsolated {
                self?.retryPlayLoop(taskID: taskID, attempt: attempt + 1)
            }
        }
    }

    private func endBackgroundHold() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private struct PlayRefusedError: Error, CustomStringConvertible {
        var description: String { "AVAudioPlayer.play() returned false" }
    }

    private static func silentWav(seconds: Int) -> Data {
        let sampleRate: UInt32 = 8000
        let sampleCount = UInt32(seconds) * sampleRate
        var data = Data()
        func appendU32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendU16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        appendU32(36 + sampleCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        appendU32(16)         // PCM chunk size
        appendU16(1)          // PCM format
        appendU16(1)          // mono
        appendU32(sampleRate) // sample rate
        appendU32(sampleRate) // byte rate (8-bit mono)
        appendU16(1)          // block align
        appendU16(8)          // bits per sample
        data.append(contentsOf: Array("data".utf8))
        appendU32(sampleCount)
        data.append(Data(repeating: 128, count: Int(sampleCount))) // 8-bit unsigned silence midpoint
        return data
    }
}
