import Foundation
import XCTest
@testable import ProxyCore

final class ConnectionLimiterTests: XCTestCase {
    func testAdmitEnforcesMaxConnectionsCap() {
        let limiter = ConnectionLimiter(maxConnections: 200)
        var ids: [UInt64] = []
        for _ in 0..<200 {
            let id = limiter.admit(kind: .tcp, idleTimeout: 60, cancel: {})
            XCTAssertNotNil(id)
            if let id { ids.append(id) }
        }
        // 201st connection must be rejected cleanly to protect Packet Tunnel memory.
        XCTAssertNil(limiter.admit(kind: .tcp, idleTimeout: 60, cancel: {}))

        let c = limiter.counts()
        XCTAssertEqual(c.tcp, 200)
        XCTAssertEqual(c.totalHandled, 200)
        XCTAssertEqual(c.rejected, 1)

        limiter.release(ids[0])
        XCTAssertNotNil(limiter.admit(kind: .tcp, idleTimeout: 60, cancel: {}))
    }

    func testReclassifyAndReapIdle() {
        let limiter = ConnectionLimiter(maxConnections: 10)
        let t0 = Date(timeIntervalSince1970: 1000)
        var cancelledA = false
        var cancelledB = false

        let idA = limiter.admit(kind: .tcp, idleTimeout: 30, now: t0) { cancelledA = true }!
        let idB = limiter.admit(kind: .tcp, idleTimeout: 30, now: t0) { cancelledB = true }!
        limiter.reclassify(idB, to: .udpStream, idleTimeout: 60, now: t0)

        XCTAssertEqual(limiter.counts().tcp, 1)
        XCTAssertEqual(limiter.counts().udpStreams, 1)

        // At t0 + 35s, idA (30s timeout) should be reaped, idB (60s timeout) should remain.
        let reaped = limiter.reapIdle(now: t0.addingTimeInterval(35))
        XCTAssertEqual(reaped, 1)
        XCTAssertTrue(cancelledA)
        XCTAssertFalse(cancelledB)
        limiter.release(idA)

        // Touch idB at t0 + 50s -> still alive at t0 + 90s.
        limiter.touch(idB, now: t0.addingTimeInterval(50))
        XCTAssertEqual(limiter.reapIdle(now: t0.addingTimeInterval(90)), 0)
        XCTAssertFalse(cancelledB)
    }

    func testTrimOldestUnderMemoryPressure() {
        let limiter = ConnectionLimiter(maxConnections: 10)
        let t0 = Date(timeIntervalSince1970: 1000)
        var cancelled: [Int] = []
        let lock = NSLock()
        for i in 0..<4 {
            _ = limiter.admit(kind: .tcp, idleTimeout: 300, now: t0.addingTimeInterval(Double(i) * 10)) {
                lock.lock(); cancelled.append(i); lock.unlock()
            }
        }
        let trimmed = limiter.trimOldest(fraction: 0.25)
        XCTAssertEqual(trimmed, 1)
        XCTAssertEqual(cancelled, [0])
    }
}
