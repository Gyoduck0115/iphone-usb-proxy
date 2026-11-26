import Foundation
import Network

/// RFC 1928 SOCKS5 wire representation for addresses, requests, and replies.
/// Supports No-Auth (0x00), CONNECT (0x01), and IPv4 (0x01) / Domain (0x03) / IPv6 (0x04).
public enum SOCKS5Address: Equatable, Hashable, Sendable, CustomStringConvertible {
    case ipv4(Data)    // 4 bytes
    case domain(String)
    case ipv6(Data)    // 16 bytes

    public var description: String {
        switch self {
        case .ipv4(let bytes):
            guard bytes.count == 4 else { return "0.0.0.0" }
            return "\(bytes[bytes.startIndex]).\(bytes[bytes.startIndex + 1]).\(bytes[bytes.startIndex + 2]).\(bytes[bytes.startIndex + 3])"
        case .domain(let host):
            return host
        case .ipv6(let bytes):
            guard bytes.count == 16 else { return "::" }
            if let addr = IPv6Address(bytes) {
                return "\(addr)"
            }
            return "::"
        }
    }

    public func toNWHost() -> NWEndpoint.Host? {
        switch self {
        case .ipv4(let data):
            guard let addr = IPv4Address(data) else { return nil }
            return .ipv4(addr)
        case .domain(let name):
            guard !name.isEmpty else { return nil }
            return .name(name, nil)
        case .ipv6(let data):
            guard let addr = IPv6Address(data) else { return nil }
            return .ipv6(addr)
        }
    }

    /// Creates a `SOCKS5Address` from a string IP literal or domain name.
    public static func fromHostString(_ host: String) -> SOCKS5Address {
        let stripped = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        if let v4 = IPv4Address(stripped) {
            return .ipv4(v4.rawValue)
        }
        if let v6 = IPv6Address(stripped) {
            return .ipv6(v6.rawValue)
        }
        return .domain(host)
    }

    /// Encodes in standard SOCKS5 address format: `[ATYP (0x01/0x03/0x04)][ADDR][PORT (u16be)]`.
    public func encodeSocksaddr(port: UInt16) throws -> Data {
        var out = Data()
        switch self {
        case .ipv4(let bytes):
            guard bytes.count == 4 else { throw SOCKS5Error.malformedAddress }
            out.append(SOCKS5Protocol.atypIPv4)
            out.append(bytes)
        case .domain(let name):
            let utf8 = Data(name.utf8)
            guard utf8.count <= 255 else { throw SOCKS5Error.domainTooLong }
            out.append(SOCKS5Protocol.atypDomain)
            out.append(UInt8(utf8.count))
            out.append(utf8)
        case .ipv6(let bytes):
            guard bytes.count == 16 else { throw SOCKS5Error.malformedAddress }
            out.append(SOCKS5Protocol.atypIPv6)
            out.append(bytes)
        }
        out.append(UInt8(port >> 8))
        out.append(UInt8(port & 0xff))
        return out
    }
}

public struct SOCKS5Endpoint: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let address: SOCKS5Address
    public let port: UInt16

    public init(address: SOCKS5Address, port: UInt16) {
        self.address = address
        self.port = port
    }

    public var description: String {
        switch address {
        case .ipv6:
            return "[\(address.description)]:\(port)"
        default:
            return "\(address.description):\(port)"
        }
    }

    public var nwEndpoint: NWEndpoint? {
        guard let host = address.toNWHost(), let nwPort = NWEndpoint.Port(rawValue: port) else {
            return nil
        }
        return .hostPort(host: host, port: nwPort)
    }
}

public enum SOCKS5Command: UInt8, Equatable, Sendable {
    case connect = 0x01
    case bind = 0x02
    case udpAssociate = 0x03
}

public enum SOCKS5Reply: UInt8, Equatable, Sendable {
    case succeeded = 0x00
    case generalFailure = 0x01
    case connectionNotAllowed = 0x02
    case networkUnreachable = 0x03
    case hostUnreachable = 0x04
    case connectionRefused = 0x05
    case ttlExpired = 0x06
    case commandNotSupported = 0x07
    case addressTypeNotSupported = 0x08
}

public struct SOCKS5Request: Equatable, Sendable {
    public let command: SOCKS5Command
    public let destination: SOCKS5Endpoint

    public init(command: SOCKS5Command, destination: SOCKS5Endpoint) {
        self.command = command
        self.destination = destination
    }
}

public enum SOCKS5Error: Error, Equatable, Sendable {
    case invalidVersion(UInt8)
    case noAcceptableAuthMethod
    case unsupportedCommand(UInt8)
    case unsupportedAddressType(UInt8)
    case malformedAddress
    case domainTooLong
    case invalidReservedByte(UInt8)
    case unexpectedEOF
}

public enum ParseResult<Value: Equatable>: Equatable {
    case needMoreData
    case parsed(Value, consumed: Int)
}

public enum SOCKS5Protocol {
    public static let version: UInt8 = 0x05
    public static let authNone: UInt8 = 0x00
    public static let authNoAcceptable: UInt8 = 0xFF

    public static let atypIPv4: UInt8 = 0x01
    public static let atypDomain: UInt8 = 0x03
    public static let atypIPv6: UInt8 = 0x04

    /// Parses the client greeting: `[VER=0x05][NMETHODS][METHODS...]`.
    /// Returns the list of offered methods if complete.
    public static func parseGreeting(_ data: Data) throws -> ParseResult<[UInt8]> {
        guard data.count >= 2 else { return .needMoreData }
        let base = data.startIndex
        let ver = data[base]
        guard ver == version else { throw SOCKS5Error.invalidVersion(ver) }
        let nMethods = Int(data[base + 1])
        let total = 2 + nMethods
        guard data.count >= total else { return .needMoreData }
        let methods = Array(data[(base + 2)..<(base + total)])
        return .parsed(methods, consumed: total)
    }

    /// Builds server method selection reply: `[0x05][METHOD]`.
    public static func encodeMethodSelection(_ method: UInt8) -> Data {
        Data([version, method])
    }

    /// Parses standard SOCKS5 address + port: `[ATYP][ADDR][PORT]`.
    public static func parseSocksaddr(_ data: Data, offset: Int = 0) throws -> ParseResult<SOCKS5Endpoint> {
        let remaining = data.count - offset
        guard remaining >= 1 else { return .needMoreData }
        let base = data.startIndex + offset
        let atyp = data[base]
        switch atyp {
        case atypIPv4:
            let needed = 1 + 4 + 2
            guard remaining >= needed else { return .needMoreData }
            let addr = Data(data[(base + 1)..<(base + 5)])
            let port = (UInt16(data[base + 5]) << 8) | UInt16(data[base + 6])
            return .parsed(SOCKS5Endpoint(address: .ipv4(addr), port: port), consumed: needed)

        case atypDomain:
            guard remaining >= 2 else { return .needMoreData }
            let len = Int(data[base + 1])
            let needed = 2 + len + 2
            guard remaining >= needed else { return .needMoreData }
            let domainBytes = data[(base + 2)..<(base + 2 + len)]
            guard let host = String(bytes: domainBytes, encoding: .utf8), !host.isEmpty else {
                throw SOCKS5Error.malformedAddress
            }
            let port = (UInt16(data[base + 2 + len]) << 8) | UInt16(data[base + 2 + len + 1])
            return .parsed(SOCKS5Endpoint(address: .domain(host), port: port), consumed: needed)

        case atypIPv6:
            let needed = 1 + 16 + 2
            guard remaining >= needed else { return .needMoreData }
            let addr = Data(data[(base + 1)..<(base + 17)])
            let port = (UInt16(data[base + 17]) << 8) | UInt16(data[base + 18])
            return .parsed(SOCKS5Endpoint(address: .ipv6(addr), port: port), consumed: needed)

        default:
            throw SOCKS5Error.unsupportedAddressType(atyp)
        }
    }

    /// Parses SOCKS5 request: `[VER=0x05][CMD][RSV=0x00][ATYP][DST.ADDR][DST.PORT]`.
    public static func parseRequest(_ data: Data) throws -> ParseResult<SOCKS5Request> {
        guard data.count >= 4 else { return .needMoreData }
        let base = data.startIndex
        let ver = data[base]
        guard ver == version else { throw SOCKS5Error.invalidVersion(ver) }
        let cmdByte = data[base + 1]
        guard let cmd = SOCKS5Command(rawValue: cmdByte) else {
            throw SOCKS5Error.unsupportedCommand(cmdByte)
        }
        let rsv = data[base + 2]
        guard rsv == 0x00 else { throw SOCKS5Error.invalidReservedByte(rsv) }

        switch try parseSocksaddr(data, offset: 3) {
        case .needMoreData:
            return .needMoreData
        case .parsed(let endpoint, let consumed):
            return .parsed(SOCKS5Request(command: cmd, destination: endpoint), consumed: 3 + consumed)
        }
    }

    /// Encodes a SOCKS5 reply packet. Defaults to bound address `0.0.0.0:0`.
    public static func encodeReply(
        _ reply: SOCKS5Reply,
        bound: SOCKS5Endpoint = SOCKS5Endpoint(address: .ipv4(Data([0, 0, 0, 0])), port: 0)
    ) -> Data {
        var out = Data([version, reply.rawValue, 0x00])
        if let encoded = try? bound.address.encodeSocksaddr(port: bound.port) {
            out.append(encoded)
        } else {
            out.append(contentsOf: [atypIPv4, 0, 0, 0, 0, 0, 0])
        }
        return out
    }

    /// Maps an `NWError` from outbound dialing to the closest RFC 1928 reply code.
    public static func replyCode(for error: NWError) -> SOCKS5Reply {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .connectionRefused
            case .ENETUNREACH, .ENETDOWN: return .networkUnreachable
            case .EHOSTUNREACH, .EHOSTDOWN: return .hostUnreachable
            case .ETIMEDOUT: return .ttlExpired
            default: return .generalFailure
            }
        case .dns:
            return .hostUnreachable
        default:
            return .generalFailure
        }
    }
}
