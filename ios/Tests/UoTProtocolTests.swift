import Foundation
import XCTest
@testable import ProxyCore

final class UoTProtocolTests: XCTestCase {
    func testDetectMagicDomains() {
        let v1 = SOCKS5Endpoint(address: .domain("sp.udp-over-tcp.arpa"), port: 0)
        let v2 = SOCKS5Endpoint(address: .domain("sp.v2.udp-over-tcp.arpa"), port: 0)
        let normal = SOCKS5Endpoint(address: .domain("example.com"), port: 443)

        XCTAssertEqual(UoTProtocol.detectVersion(for: v1), .v1)
        XCTAssertEqual(UoTProtocol.detectVersion(for: v2), .v2)
        XCTAssertNil(UoTProtocol.detectVersion(for: normal))
    }

    func testV2RequestUsesStandardSocksaddrATYP() throws {
        // SagerNet uot.ReadRequest reads isConnect (1B) + metadata.SocksaddrSerializer (0x01/0x03/0x04).
        let req = UoTV2Request(
            isConnect: true,
            destination: SOCKS5Endpoint(address: .ipv4(Data([8, 8, 8, 8])), port: 53)
        )
        let encoded = try UoTProtocol.encodeV2Request(req)
        XCTAssertEqual(encoded, Data([0x01, 0x01, 8, 8, 8, 8, 0x00, 0x35]))
        XCTAssertEqual(try UoTProtocol.parseV2Request(encoded), .parsed(req, consumed: 8))
        XCTAssertEqual(try UoTProtocol.parseV2Request(encoded.prefix(5)), .needMoreData)
    }

    func testNonConnectPacketUsesUoTAddrParserATYP() throws {
        // SagerNet uot.AddrParser uses 0x00=IPv4, 0x01=IPv6, 0x02=FQDN (NOT RFC 1928 values).
        let v4Packet = UoTPacket(
            destination: SOCKS5Endpoint(address: .ipv4(Data([1, 1, 1, 1])), port: 443),
            payload: Data("quic-hello".utf8)
        )
        let encoded = try UoTProtocol.encodePacket(v4Packet)
        XCTAssertEqual(encoded[0], 0x00) // uotAtypIPv4
        XCTAssertEqual(try UoTProtocol.parsePacket(encoded), .parsed(v4Packet, consumed: encoded.count))

        let domainPacket = UoTPacket(
            destination: SOCKS5Endpoint(address: .domain("dns.google"), port: 53),
            payload: Data([0x12, 0x34, 0x56])
        )
        let domainEncoded = try UoTProtocol.encodePacket(domainPacket)
        XCTAssertEqual(domainEncoded[0], 0x02) // uotAtypDomain
        XCTAssertEqual(try UoTProtocol.parsePacket(domainEncoded), .parsed(domainPacket, consumed: domainEncoded.count))
    }

    func testConnectFrameRoundTripAndPartialRead() throws {
        let payload = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let frame = try UoTProtocol.encodeConnectFrame(payload)
        XCTAssertEqual(frame, Data([0x00, 0x04, 0xAA, 0xBB, 0xCC, 0xDD]))
        XCTAssertEqual(UoTProtocol.parseConnectFrame(frame.prefix(1)), .needMoreData)
        XCTAssertEqual(UoTProtocol.parseConnectFrame(frame.prefix(4)), .needMoreData)
        XCTAssertEqual(UoTProtocol.parseConnectFrame(frame), .parsed(payload, consumed: 6))
    }
}
