import Darwin
import Foundation

#if canImport(CoreTelephony) && os(iOS)
import CoreTelephony
#endif

/// Inspects cellular interface state (`pdp_ip*`) and radio technology for diagnostics.
/// Inspired by `viktor-svirsky/tether`'s `Interfaces` / `Cellular` helpers.
public struct CellularStatus: Equatable, Sendable {
    public let hasIPv4: Bool
    public let hasIPv6: Bool
    public let interfaceName: String?
    public let radioTechnology: String

    public init(hasIPv4: Bool, hasIPv6: Bool, interfaceName: String?, radioTechnology: String) {
        self.hasIPv4 = hasIPv4
        self.hasIPv6 = hasIPv6
        self.interfaceName = interfaceName
        self.radioTechnology = radioTechnology
    }

    public var summary: String {
        guard let iface = interfaceName else {
            return "셀룰러 비활성 (\(radioTechnology))"
        }
        let families: String
        switch (hasIPv4, hasIPv6) {
        case (true, true): families = "IPv4 + IPv6"
        case (true, false): families = "IPv4"
        case (false, true): families = "IPv6 전용 (NAT64 자동)"
        case (false, false): families = "주소 없음"
        }
        return "\(iface) · \(families) · \(radioTechnology)"
    }
}

public enum CellularProbe {
    public static func current() -> CellularStatus {
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        var foundIface: String?
        var hasV4 = false
        var hasV6 = false

        if getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer {
            defer { freeifaddrs(first) }
            var current: UnsafeMutablePointer<ifaddrs>? = first
            while let ptr = current {
                let ifa = ptr.pointee
                let flags = Int32(bitPattern: ifa.ifa_flags)
                let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
                if isUp, let namePtr = ifa.ifa_name, let addrPtr = ifa.ifa_addr {
                    let name = String(cString: namePtr)
                    if name.hasPrefix("pdp_ip") {
                        let family = Int32(addrPtr.pointee.sa_family)
                        if family == AF_INET {
                            hasV4 = true
                            if foundIface == nil || name == "pdp_ip0" { foundIface = name }
                        } else if family == AF_INET6 {
                            // Exclude link-local fe80:: addresses.
                            let sin6 = addrPtr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                            let firstByte = withUnsafeBytes(of: sin6.sin6_addr) { $0[0] }
                            let secondByte = withUnsafeBytes(of: sin6.sin6_addr) { $0[1] }
                            let isLinkLocal = (firstByte == 0xfe) && ((secondByte & 0xc0) == 0x80)
                            if !isLinkLocal {
                                hasV6 = true
                                if foundIface == nil || name == "pdp_ip0" { foundIface = name }
                            }
                        }
                    }
                }
                current = ifa.ifa_next
            }
        }

        return CellularStatus(
            hasIPv4: hasV4,
            hasIPv6: hasV6,
            interfaceName: foundIface,
            radioTechnology: currentRadioTechnology()
        )
    }

    private static func currentRadioTechnology() -> String {
        #if canImport(CoreTelephony) && os(iOS)
        let info = CTTelephonyNetworkInfo()
        guard let radios = info.serviceCurrentRadioAccessTechnology, !radios.isEmpty else {
            return "신호 없음"
        }
        let raw = info.dataServiceIdentifier.flatMap { radios[$0] } ?? radios.values.first ?? ""
        let prefix = "CTRadioAccessTechnology"
        if raw.hasPrefix(prefix) {
            return String(raw.dropFirst(prefix.count))
        }
        return raw.isEmpty ? "알 수 없음" : raw
        #else
        return "macOS/Simulator"
        #endif
    }
}
