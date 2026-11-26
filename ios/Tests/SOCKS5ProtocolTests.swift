import Foundation
import XCTest
@testable import ProxyCore

final class SOCKS5ProtocolTests: XCTestCase {
    func testParseGreetingCompleteAndPartial() throws {
        XCTAssertEqual(try SOCKS5Protocol.parseGreeting(Data([0x05])), .needMoreData)
        XCTAssertEqual(try SOCKS5Protocol.parseGreeting(Data([0x05, 0x02, 0x00])), .needMoreData)

        let greeting = Data([0x05, 0x02, 0x00, 0x02, 0xAA])
        let result = try SOCKS5Protocol.parseGreeting(greeting)
        XCTAssertEqual(result, .parsed([0x00, 0x02], consumed: 4))
    }

    func testParseGreetingRejectsWrongVersion() {
        XCTAssertThrowsError(try SOCKS5Protocol.parseGreeting(Data([0x04, 0x01, 0x00]))) { error in
            XCTAssertEqual(error as? SOCKS5Error, .invalidVersion(0x04))
        }
    }

    func testParseConnectIPv4() throws {
        let raw = Data([0x05, 0x01, 0x00, 0x01, 1, 1, 1, 1, 0x01, 0xBB])
        let result = try SOCKS5Protocol.parseRequest(raw)
        let expected = SOCKS5Request(
            command: .connect,
            destination: SOCKS5Endpoint(address: .ipv4(Data([1, 1, 1, 1])), port: 443)
        )
        XCTAssertEqual(result, .parsed(expected, consumed: 10))
        XCTAssertEqual(expected.destination.description, "1.1.1.1:443")
    }

    func testParseConnectDomainWithTrailingBytes() throws {
        let domain = "example.com"
        var raw = Data([0x05, 0x01, 0x00, 0x03, UInt8(domain.utf8.count)])
        raw.append(contentsOf: domain.utf8)
        raw.append(contentsOf: [0x00, 0x50, 0xDE, 0xAD]) // port 80 + 2 pipelined bytes

        let result = try SOCKS5Protocol.parseRequest(raw)
        let expected = SOCKS5Request(
            command: .connect,
            destination: SOCKS5Endpoint(address: .domain(domain), port: 80)
        )
        XCTAssertEqual(result, .parsed(expected, consumed: raw.count - 2))
    }

    func testParseConnectIPv6() throws {
        var v6 = Data(repeating: 0, count: 16)
        v6[0] = 0x26; v6[1] = 0x06; v6[15] = 0x01
        var raw = Data([0x05, 0x01, 0x00, 0x04])
        raw.append(v6)
        raw.append(contentsOf: [0x00, 0x35]) // port 53

        let result = try SOCKS5Protocol.parseRequest(raw)
        let expected = SOCKS5Request(
            command: .connect,
            destination: SOCKS5Endpoint(address: .ipv6(v6), port: 53)
        )
        XCTAssertEqual(result, .parsed(expected, consumed: 22))
    }

    func testEncodeReplyAndRoundTripSocksaddr() throws {
        let reply = SOCKS5Protocol.encodeReply(.succeeded)
        XCTAssertEqual(reply, Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))

        let ep = SOCKS5Endpoint(address: .domain("cloudflare-dns.com"), port: 443)
        let encoded = try ep.address.encodeSocksaddr(port: ep.port)
        XCTAssertEqual(try SOCKS5Protocol.parseSocksaddr(encoded), .parsed(ep, consumed: encoded.count))
    }
}
