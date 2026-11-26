import Foundation

/// Detects the provisioning profile expiration date on sideloaded builds (free Apple ID = 7 days)
/// and surfaces a warning 3 days before expiry. Modeled after `viktor-svirsky/tether`'s `AppExpiry.swift`.
public enum AppExpiry {
    public static let warnBefore: TimeInterval = 3 * 86_400

    /// Reads `embedded.mobileprovision` from the main app bundle (`nil` on simulator / `swift test`).
    public static var installed: Date? {
        Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap(date(fromProfile:))
    }

    /// Extracts `ExpirationDate` from the clear-text XML plist embedded inside a CMS `.mobileprovision`.
    public static func date(fromProfile data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data[start.lowerBound..<end.upperBound],
                  format: nil
              )
        else { return nil }
        return (plist as? [String: Any])?["ExpirationDate"] as? Date
    }

    /// Warning message when 3 days or fewer remain before profile expiry; `nil` otherwise.
    public static func warning(expires: Date, now: Date, calendar: Calendar = .current) -> String? {
        guard expires.timeIntervalSince(now) <= warnBefore else { return nil }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: expires)
        ).day ?? 0
        let when: String
        if days <= 0 {
            when = "오늘"
        } else if days == 1 {
            when = "내일"
        } else {
            when = "\(days)일 후"
        }
        return "개발자 서명이 \(when) 만료됩니다. SideStore/AltStore 또는 Xcode로 재서명하세요."
    }
}
