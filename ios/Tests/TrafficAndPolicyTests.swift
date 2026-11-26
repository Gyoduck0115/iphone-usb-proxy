import Foundation
import XCTest
@testable import ProxyCore

final class TrafficAndPolicyTests: XCTestCase {
    func testTrafficSamplerComputesBitrates() {
        var sampler = TrafficSampler()
        let t0 = Date(timeIntervalSince1970: 100)
        XCTAssertNil(sampler.sample(TrafficTotals(bytesUp: 0, bytesDown: 0), at: t0))

        let speeds = sampler.sample(TrafficTotals(bytesUp: 125_000, bytesDown: 250_000), at: t0.addingTimeInterval(1))
        XCTAssertEqual(speeds?.upBps ?? -1, 1_000_000, accuracy: 0.1)
        XCTAssertEqual(speeds?.downBps ?? -1, 2_000_000, accuracy: 0.1)
    }

    func testKeepAlivePolicyAudioEvents() {
        XCTAssertNil(KeepAlivePolicy.restart(after: .interruptionBegan, started: false))
        XCTAssertEqual(KeepAlivePolicy.restart(after: .interruptionBegan, started: true), .holdOn)
        XCTAssertEqual(KeepAlivePolicy.restart(after: .interruptionEnded, started: true), .holdOn)
        XCTAssertEqual(KeepAlivePolicy.restart(after: .mediaServicesLost, started: true), .holdOn)
        XCTAssertEqual(KeepAlivePolicy.restart(after: .mediaServicesReset, started: true), .rebuild)
    }

    func testIdleStopPolicyTriggersOnlyInBackgroundWithoutTraffic() {
        var idle = IdleStopPolicy()
        let t0 = Date(timeIntervalSince1970: 1000)

        // Active on screen never triggers idle stop.
        XCTAssertFalse(idle.check(running: true, activeConnections: 0, trafficChanged: false, sceneActive: true, timeout: .thirtyMinutes, now: t0))
        // Starts counting in background with 0 connections.
        XCTAssertFalse(idle.check(running: true, activeConnections: 0, trafficChanged: false, sceneActive: false, timeout: .thirtyMinutes, now: t0))
        XCTAssertFalse(idle.check(running: true, activeConnections: 0, trafficChanged: false, sceneActive: false, timeout: .thirtyMinutes, now: t0.addingTimeInterval(1799)))
        XCTAssertTrue(idle.check(running: true, activeConnections: 0, trafficChanged: false, sceneActive: false, timeout: .thirtyMinutes, now: t0.addingTimeInterval(1800)))
    }

    func testAppExpiryParsesMobileProvisionPlist() {
        let xml = """
        BINARY_CMS_PREFIX<?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>ExpirationDate</key>
            <date>2026-12-01T12:00:00Z</date>
        </dict>
        </plist>BINARY_TRAILER
        """
        let parsed = AppExpiry.date(fromProfile: Data(xml.utf8))
        XCTAssertNotNil(parsed)

        if let expires = parsed {
            // 5 days before expiry -> no warning
            XCTAssertNil(AppExpiry.warning(expires: expires, now: expires.addingTimeInterval(-5 * 86_400)))
            // 2 days before expiry -> warning present
            XCTAssertNotNil(AppExpiry.warning(expires: expires, now: expires.addingTimeInterval(-2 * 86_400)))
        }
    }

    func testLogRedactionKeepsLoopbackAndMasksPublicIPs() {
        let line = "listening on 127.0.0.1:1080, dialed 203.0.114.55:443 and 2606:4700:4700::1111"
        let redacted = LogRedaction.redact(line)
        XCTAssertTrue(redacted.contains("127.0.0.1:1080"))
        XCTAssertTrue(redacted.contains("203.0.…:443"))
        XCTAssertFalse(redacted.contains("203.0.114.55"))
        XCTAssertTrue(redacted.contains("2606:4700:…"))
    }

    func testDebugLogRotatesAndExports() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usbproxy-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = DebugLog(directory: dir, segmentLimit: 120)
        for i in 0..<10 {
            log.append("line \(i) connected to 1.2.3.4")
        }
        let exported = log.export(header: "USBProxy Test")
        XCTAssertTrue(exported.contains("USBProxy Test"))
        XCTAssertTrue(exported.contains("1.2.…"))
    }
}
