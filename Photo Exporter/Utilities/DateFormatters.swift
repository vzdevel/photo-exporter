//
//  DateFormatters.swift
//  Photo Exporter
//

import Foundation

enum DateFormatters {
    /// Formatter for displaying date and time with seconds: "2024-05-18 14:30:22"
    static let displayDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()

    /// Formatter for displaying date and time with seconds: "2024-05-18 14:30:22" in a given timezone
    static func dateTimeString(for date: Date?, in timeZone: TimeZone = .current) -> String {
        guard let date = date else { return "No Date & Time" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// Formatter for displaying short date: "May 18, 2024"
    static func mediumDateString(for date: Date, in timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// Formatter for displaying time: "2:30:22 PM"
    static func mediumTimeString(for date: Date, in timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// Standard EXIF date/time string format: "yyyy:MM:dd HH:mm:ss"
    static let exifDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// IPTC Date: "yyyyMMdd"
    static let iptcDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// IPTC Time: "HHmmss"
    static let iptcTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Format timezone offset as "+HH:mm" or "-HH:mm" (EXIF 2.31 standard: OffsetTime)
    static func exifTimezoneOffset(for date: Date, in timeZone: TimeZone = .current) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "-"
        let absSeconds = abs(seconds)
        let hours = absSeconds / 3600
        let minutes = (absSeconds % 3600) / 60
        return String(format: "%@%02d:%02d", sign, hours, minutes)
    }

    /// Extract a human-readable city or location name from a timezone identifier
    /// e.g. "Indian/Chagos" -> "Chagos", "America/New_York" -> "New York", "Asia/Kolkata" -> "Kolkata"
    static func cityOrRegionName(for timeZone: TimeZone) -> String? {
        let id = timeZone.identifier
        guard id.contains("/") else { return nil }
        guard let lastComponent = id.split(separator: "/").last else { return nil }
        let cleanName = lastComponent.replacingOccurrences(of: "_", with: " ")
        let upper = cleanName.uppercased()
        if upper.contains("GMT") || upper.contains("UTC") || upper.hasPrefix("ETC") {
            return nil
        }
        return cleanName
    }

    /// Check if an abbreviation is an authentic named code (e.g. "PDT", "IST", "JST", "BST")
    /// rather than a generic or potentially conflicting offset string like "GMT+6", "UTC-7", "+05"
    static func isAuthenticNamedAbbreviation(_ abbrev: String) -> Bool {
        guard abbrev.count >= 2 && abbrev.count <= 5 else { return false }
        // Must contain only ASCII letters
        guard abbrev.rangeOfCharacter(from: CharacterSet.letters.inverted) == nil else { return false }
        let upper = abbrev.uppercased()
        guard upper != "GMT" && upper != "UTC" else { return false }
        return true
    }

    /// Short timezone offset: "UTC+8", "UTC-5", "UTC+5:30" (without name or city)
    static func shortUTCOffsetString(for date: Date, in timeZone: TimeZone = .current) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "-"
        let absSec = abs(seconds)
        let hours = absSec / 3600
        let minutes = (absSec % 3600) / 60
        return minutes == 0 ? "UTC\(sign)\(hours)" : String(format: "UTC%@%d:%02d", sign, hours, minutes)
    }

    /// Format friendly timezone string: "UTC-7 (PDT)", "UTC+5:30 (IST)", or "UTC+5 (Chagos)"
    static func friendlyTimezone(for date: Date, in timeZone: TimeZone = .current) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "-"
        let absSec = abs(seconds)
        let hours = absSec / 3600
        let minutes = (absSec % 3600) / 60
        let offsetStr = minutes == 0 ? "UTC\(sign)\(hours)" : String(format: "UTC%@%d:%02d", sign, hours, minutes)

        // 1. If there is an authentic alphabetic abbreviation (like "PDT", "IST", "JST", "CDT")
        if let abbrev = timeZone.abbreviation(for: date), isAuthenticNamedAbbreviation(abbrev) {
            return "\(offsetStr) (\(abbrev))"
        }

        // 2. Otherwise use the city / region name (e.g. "Chagos", "Shanghai", "Chicago")
        if let city = cityOrRegionName(for: timeZone) {
            return "\(offsetStr) (\(city))"
        }

        // 3. Fallback to just the offset string
        return offsetStr
    }

    /// Full formatted string: "2024-05-18 14:30:22 • UTC-7 (PDT)"
    static func fullTimestampString(for date: Date?, in timeZone: TimeZone = .current) -> String {
        guard let date = date else { return "No Date & Time" }
        let dtFormatter = DateFormatter()
        dtFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dtFormatter.timeZone = timeZone
        let datePart = dtFormatter.string(from: date)
        let tzPart = friendlyTimezone(for: date, in: timeZone)
        return "\(datePart) • \(tzPart)"
    }
}
