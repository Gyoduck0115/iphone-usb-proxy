import Foundation

/// SagerNet UDP-over-TCP (UoT) v1 and v2 wire protocol parser and encoder.
/// Byte-for-byte compatible with `sing-box`'s `socks` outbound `udp_over_tcp` setting:
/// - v1 magic FQDN: `sp.udp-over-tcp.arpa`
/// - v2 magic FQDN: `sp.v2.udp-over-tcp.arpa`
///
/// Important wire distinction from `SagerNet/sing`:
/// - UoT v2 initial Request header uses standard SOCKS5 ATYP (`0x01`=IPv4, `0x03`=FQDN, `0x04`=IPv6).
/// - UoT v1 and v2 non-connect per-packet headers use UoT ATYP (`0x00`=IPv4, `0x01`=IPv6, `0x02`=FQDN).
public enum UoTVersion: Int, Equatable, Sendable {
    case v1 = 1
    case v2 = 2
}

public struct UoTV2Request: Equatable, Sendable {
    public let isConnect: Bool
    public let destination: SOCKS5Endpoint

    public init(isConnect: Bool, destination: SOCKS5Endpoint) {
        self.isConnect = isConnect
        self.destination = destination
    }
}

public struct UoTPacket: Equatable, Sendable {
    public let destination: SOCKS5Endpoint
    public let payload: Data

    public init(destination: SOCKS5Endpoint, payload: Data) {
        self.destination = destination
        self.payload = payload
    }
}

public enum UoTError: Error, Equatable, Sendable {
    case unsupportedAddressType(UInt8)
    case malformedAddress
    case domainTooLong
    case payloadTooLarge(Int)
}

public enum UoTProtocol {
    public static let magicAddressV1 = "sp.udp-over-tcp.arpa"
    public static let magicAddressV2 = "sp.v2.udp-over-tcp.arpa"

    // UoT AddrParser ATYP bytes (different from RFC 1928 SOCKS5 ATYP!)
    public static let uotAtypIPv4: UInt8 = 0x00
    public static let uotAtypIPv6: UInt8 = 0x01
    public static let uotAtypDomain: UInt8 = 0x02

    /// Detects whether a SOCKS5 destination is a SagerNet UoT magic address.
    public static func detectVersion(for endpoint: SOCKS5Endpoint) -> UoTVersion? {
        guard case .domain(let host) = endpoint.address else { return nil }
        switch host.lowercased() {
        case magicAddressV2:
            return .v2
        case magicAddressV1:
            return .v1
        default:
            return nil
        }
    }

    /// Parses UoT v2 stream header: `[isConnect (u8)][Socksaddr (ATYP 0x01/0x03/0x04 + addr + u16be port)]`.
    public static func parseV2Request(_ data: Data) throws -> ParseResult<UoTV2Request> {
        guard data.count >= 2 else { return .needMoreData }
        let base = data.startIndex
        let isConnect = data[base] != 0
        switch try SOCKS5Protocol.parseSocksaddr(data, offset: 1) {
        case .needMoreData:
            return .needMoreData
        case .parsed(let dest, let consumed):
            return .parsed(UoTV2Request(isConnect: isConnect, destination: dest), consumed: 1 + consumed)
        }
    }

    /// Encodes a UoT v2 stream header.
    public static func encodeV2Request(_ request: UoTV2Request) throws -> Data {
        var out = Data([request.isConnect ? 0x01 : 0x00])
        out.append(try request.destination.address.encodeSocksaddr(port: request.destination.port))
        return out
    }

    /// Parses UoT AddrParser address + port: `[ATYP (0x00/0x01/0x02)][ADDR][PORT (u16be)]`.
    public static func parseUoTAddr(_ data: Data, offset: Int = 0) throws -> ParseResult<SOCKS5Endpoint> {
        let remaining = data.count - offset
        guard remaining >= 1 else { return .needMoreData }
        let base = data.startIndex + offset
        let atyp = data[base]
        switch atyp {
        case uotAtypIPv4:
            let needed = 1 + 4 + 2
            guard remaining >= needed else { return .needMoreData }
            let addr = Data(data[(base + 1)..<(base + 5)])
            let port = (UInt16(data[base + 5]) << 8) | UInt16(data[base + 6])
            return .parsed(SOCKS5Endpoint(address: .ipv4(addr), port: port), consumed: needed)

        case uotAtypIPv6:
            let needed = 1 + 16 + 2
            guard remaining >= needed else { return .needMoreData }
            let addr = Data(data[(base + 1)..<(base + 17)])
            let port = (UInt16(data[base + 17]) << 8) | UInt16(data[base + 18])
            return .parsed(SOCKS5Endpoint(address: .ipv6(addr), port: port), consumed: needed)

        case uotAtypDomain:
            guard remaining >= 2 else { return .needMoreData }
            let len = Int(data[base + 1])
            let needed = 2 + len + 2
            guard remaining >= needed else { return .needMoreData }
            let domainBytes = data[(base + 2)..<(base + 2 + len)]
            guard let host = String(bytes: domainBytes, encoding: .utf8), !host.isEmpty else {
                throw UoTError.malformedAddress
            }
            let port = (UInt16(data[base + 2 + len]) << 8) | UInt16(data[base + 2 + len + 1])
            return .parsed(SOCKS5Endpoint(address: .domain(host), port: port), consumed: needed)

        default:
            throw UoTError.unsupportedAddressType(atyp)
        }
    }

    /// Encodes a destination using UoT AddrParser ATYP (`0x00`=IPv4, `0x01`=IPv6, `0x02`=FQDN).
    public static func encodeUoTAddr(_ endpoint: SOCKS5Endpoint) throws -> Data {
        var out = Data()
        switch endpoint.address {
        case .ipv4(let bytes):
            guard bytes.count == 4 else { throw UoTError.malformedAddress }
            out.append(uotAtypIPv4)
            out.append(bytes)
        case .ipv6(let bytes):
            guard bytes.count == 16 else { throw UoTError.malformedAddress }
            out.append(uotAtypIPv6)
            out.append(bytes)
        case .domain(let host):
            let utf8 = Data(host.utf8)
            guard utf8.count <= 255 else { throw UoTError.domainTooLong }
            out.append(uotAtypDomain)
            out.append(UInt8(utf8.count))
            out.append(utf8)
        }
        out.append(UInt8(endpoint.port >> 8))
        out.append(UInt8(endpoint.port & 0xff))
        return out
    }

    /// Parses one framed UDP packet in non-connect mode (UoT v1 or v2 `isConnect == false`):
    /// `[UoTAddr][length (u16be)][payload]`.
    public static func parsePacket(_ data: Data) throws -> ParseResult<UoTPacket> {
        switch try parseUoTAddr(data, offset: 0) {
        case .needMoreData:
            return .needMoreData
        case .parsed(let dest, let addrLen):
            guard data.count >= addrLen + 2 else { return .needMoreData }
            let base = data.startIndex + addrLen
            let length = Int((UInt16(data[base]) << 8) | UInt16(data[base + 1]))
            let total = addrLen + 2 + length
            guard data.count >= total else { return .needMoreData }
            let payload = Data(data[(base + 2)..<(base + 2 + length)])
            return .parsed(UoTPacket(destination: dest, payload: payload), consumed: total)
        }
    }

    /// Encodes one framed UDP packet in non-connect mode (UoT v1 or v2 `isConnect == false`).
    public static func encodePacket(_ packet: UoTPacket) throws -> Data {
        guard packet.payload.count <= Int(UInt16.max) else {
            throw UoTError.payloadTooLarge(packet.payload.count)
        }
        var out = try encodeUoTAddr(packet.destination)
        let len = UInt16(packet.payload.count)
        out.append(UInt8(len >> 8))
        out.append(UInt8(len & 0xff))
        out.append(packet.payload)
        return out
    }

    /// Parses one framed UDP payload in connect mode (UoT v2 `isConnect == true`):
    /// `[length (u16be)][payload]`.
    public static func parseConnectFrame(_ data: Data) -> ParseResult<Data> {
        guard data.count >= 2 else { return .needMoreData }
        let base = data.startIndex
        let length = Int((UInt16(data[base]) << 8) | UInt16(data[base + 1]))
        let total = 2 + length
        guard data.count >= total else { return .needMoreData }
        let payload = Data(data[(base + 2)..<(base + total)])
        return .parsed(payload, consumed: total)
    }

    /// Encodes one framed UDP payload in connect mode (UoT v2 `isConnect == true`).
    public static func encodeConnectFrame(_ payload: Data) throws -> Data {
        guard payload.count <= Int(UInt16.max) else {
            throw UoTError.payloadTooLarge(payload.count)
        }
        var out = Data(capacity: 2 + payload.count)
        let len = UInt16(payload.count)
        out.append(UInt8(len >> 8))
        out.append(UInt8(len & 0xff))
        out.append(payload)
        return out
    }
}
