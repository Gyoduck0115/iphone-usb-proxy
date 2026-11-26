import Foundation
import Network
import XCTest
@testable import ProxyCore

final class ProxyServerIntegrationTests: XCTestCase {
    func testSOCKS5TCPEchoRelay() throws {
        let echoPort = try startTCPEchoServer()
        let proxy = ProxyServer(config: .testing(port: 0))
        let readyExp = expectation(description: "proxy ready")
        var proxyPort: UInt16 = 0
        proxy.start { result in
            if case .success(let p) = result { proxyPort = p }
            readyExp.fulfill()
        }
        wait(for: [readyExp], timeout: 5)
        defer { proxy.stop() }
        XCTAssertGreaterThan(proxyPort, 0)

        let conn = NWConnection(
            to: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: proxyPort)!),
            using: .tcp
        )
        let queue = DispatchQueue(label: "test.socks5.tcp")
        let done = expectation(description: "echo received")
        var receivedEcho = Data()

        conn.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            // 1. Greeting
            conn.send(content: Data([0x05, 0x01, 0x00]), completion: .contentProcessed { _ in
                conn.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, _ in
                    XCTAssertEqual(data, Data([0x05, 0x00]))
                    // 2. CONNECT 127.0.0.1:<echoPort>
                    let req = Data([
                        0x05, 0x01, 0x00, 0x01,
                        127, 0, 0, 1,
                        UInt8(echoPort >> 8), UInt8(echoPort & 0xff)
                    ])
                    conn.send(content: req, completion: .contentProcessed { _ in
                        conn.receive(minimumIncompleteLength: 10, maximumLength: 10) { rep, _, _, _ in
                            XCTAssertEqual(rep?.prefix(2), Data([0x05, 0x00]))
                            // 3. Echo payload
                            let payload = Data("hello-usb-proxy".utf8)
                            conn.send(content: payload, completion: .contentProcessed { _ in
                                conn.receive(minimumIncompleteLength: payload.count, maximumLength: 64) { echo, _, _, _ in
                                    receivedEcho = echo ?? Data()
                                    done.fulfill()
                                }
                            })
                        }
                    })
                }
            })
        }
        conn.start(queue: queue)
        wait(for: [done], timeout: 5)
        conn.cancel()

        XCTAssertEqual(receivedEcho, Data("hello-usb-proxy".utf8))
        let snap = proxy.snapshot()
        XCTAssertGreaterThanOrEqual(snap.traffic.bytesUp, 15)
        XCTAssertGreaterThanOrEqual(snap.traffic.bytesDown, 15)
    }

    func testUoTV2ConnectAndNonConnectUDPEcho() throws {
        let udpPort = try startUDPEchoServer()
        let proxy = ProxyServer(config: .testing(port: 0))
        let readyExp = expectation(description: "proxy ready")
        var proxyPort: UInt16 = 0
        proxy.start { result in
            if case .success(let p) = result { proxyPort = p }
            readyExp.fulfill()
        }
        wait(for: [readyExp], timeout: 5)
        defer { proxy.stop() }

        // Test UoT v2 non-connect mode (the mode sing-box TUN uses via ListenPacket).
        let conn = NWConnection(
            to: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: proxyPort)!),
            using: .tcp
        )
        let queue = DispatchQueue(label: "test.uot.udp")
        let done = expectation(description: "uot udp echo received")
        var replyPayload = Data()

        let magic = UoTProtocol.magicAddressV2
        var connectReq = Data([0x05, 0x01, 0x00, 0x03, UInt8(magic.utf8.count)])
        connectReq.append(contentsOf: magic.utf8)
        connectReq.append(contentsOf: [0x00, 0x00]) // port 0

        let target = SOCKS5Endpoint(address: .ipv4(Data([127, 0, 0, 1])), port: udpPort)
        let uotHeader = try UoTProtocol.encodeV2Request(UoTV2Request(isConnect: false, destination: target))
        let packetFrame = try UoTProtocol.encodePacket(UoTPacket(destination: target, payload: Data("udp-over-tcp".utf8)))

        conn.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            conn.send(content: Data([0x05, 0x01, 0x00]), completion: .contentProcessed { _ in
                conn.receive(minimumIncompleteLength: 2, maximumLength: 2) { _, _, _, _ in
                    conn.send(content: connectReq, completion: .contentProcessed { _ in
                        conn.receive(minimumIncompleteLength: 10, maximumLength: 10) { rep, _, _, _ in
                            XCTAssertEqual(rep?.prefix(2), Data([0x05, 0x00]))
                            var firstWrite = uotHeader
                            firstWrite.append(packetFrame)
                            conn.send(content: firstWrite, completion: .contentProcessed { _ in
                                conn.receive(minimumIncompleteLength: packetFrame.count, maximumLength: 256) { data, _, _, _ in
                                    if let data, case .parsed(let pkt, _) = try? UoTProtocol.parsePacket(data) {
                                        replyPayload = pkt.payload
                                    }
                                    done.fulfill()
                                }
                            })
                        }
                    })
                }
            })
        }
        conn.start(queue: queue)
        wait(for: [done], timeout: 5)
        conn.cancel()

        XCTAssertEqual(replyPayload, Data("udp-over-tcp".utf8))
    }

    // MARK: - Local Echo Helpers

    private func startTCPEchoServer() throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "test.echo.tcp")
        let exp = expectation(description: "tcp echo ready")
        var boundPort: UInt16 = 0
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                boundPort = listener.port?.rawValue ?? 0
                exp.fulfill()
            }
        }
        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            func loop() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        conn.send(content: data, completion: .contentProcessed { _ in
                            if !isComplete && error == nil { loop() } else { conn.cancel() }
                        })
                    } else {
                        conn.cancel()
                    }
                }
            }
            loop()
        }
        listener.start(queue: queue)
        addTeardownBlock { listener.cancel() }
        wait(for: [exp], timeout: 5)
        return boundPort
    }

    private func startUDPEchoServer() throws -> UInt16 {
        let params = NWParameters.udp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "test.echo.udp")
        let exp = expectation(description: "udp echo ready")
        var boundPort: UInt16 = 0
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                boundPort = listener.port?.rawValue ?? 0
                exp.fulfill()
            }
        }
        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receiveMessage { data, _, _, _ in
                if let data {
                    conn.send(content: data, completion: .contentProcessed { _ in })
                }
            }
        }
        listener.start(queue: queue)
        addTeardownBlock { listener.cancel() }
        wait(for: [exp], timeout: 5)
        return boundPort
    }
}
