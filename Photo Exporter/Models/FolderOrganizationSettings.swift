//
//  FolderOrganizationSettings.swift
//  Photo Exporter
//
//  Created by Antigravity on 2026-11-07.
//

import Foundation
import SwiftUI
import Combine

/// Manages settings and date-based path formatting for organizing exported photos into folders.
/// Replaces tokens (yyyy, yy, MM, dd, case-sensitive) while preserving custom folder text.
final class FolderOrganizationSettings: ObservableObject {
    static let shared = FolderOrganizationSettings()

    private let isEnabledKey = "PhotoExporter_FolderOrganization_Enabled"
    private let patternKey = "PhotoExporter_FolderOrganization_Pattern"

    /// Common invalid file/folder name characters across filesystems (FAT, NTFS, SMB, POSIX)
    static let invalidFileNameCharacters: CharacterSet = CharacterSet(charactersIn: "?*|<>:\"").union(.controlCharacters)

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: isEnabledKey)
        }
    }

    @Published var pattern: String {
        didSet {
            // Only persist valid patterns; do not persist when invalid file name characters are present
            if !Self.hasInvalidFileNameCharacters(pattern) {
                UserDefaults.standard.set(pattern, forKey: patternKey)
            }
        }
    }

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "PhotoExporter_FolderOrganization_Enabled")
        let savedPattern = UserDefaults.standard.string(forKey: "PhotoExporter_FolderOrganization_Pattern")
        self.pattern = (savedPattern != nil && !savedPattern!.isEmpty) ? savedPattern! : "yyyy/MM"
    }

    // MARK: - Validation

    /// Returns the first unsupported filename character (such as ?, *, |, <, >, :, ") if present in the pattern
    static func firstInvalidCharacter(in pattern: String) -> Character? {
        for scalar in pattern.unicodeScalars {
            if invalidFileNameCharacters.contains(scalar) {
                return Character(scalar)
            }
        }
        return nil
    }

    static func hasInvalidFileNameCharacters(_ pattern: String) -> Bool {
        firstInvalidCharacter(in: pattern) != nil
    }

    // MARK: - Date Formatting

    /// Formats a date into a subfolder path using the given pattern and timezone.
    /// If isEnabled is false or date is nil, returns empty string ("").
    func subfolderPath(for date: Date?, in timeZone: TimeZone = .current) -> String {
        guard isEnabled, let date = date else { return "" }
        return Self.format(date: date, in: timeZone, pattern: pattern)
    }

    /// Pure formatting function for a given date, timezone, and pattern string.
    /// Replaces year, month, and day tokens (case-insensitive) and preserves custom literal text.
    static func format(date: Date, in timeZone: TimeZone = .current, pattern: String) -> String {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return ""
        }

        let yyyyStr = String(format: "%04d", year)
        let yyStr = String(format: "%02d", abs(year) % 100)
        let mmStr = String(format: "%02d", month)
        let ddStr = String(format: "%02d", day)

        var result = trimmed
        // Case-sensitive token replacement: yyyy, yy, MM, dd
        // (YYYY, YY, mm, DD etc. are preserved as literal text)
        // Replace 4-digit year before 2-digit year
        result = result.replacingOccurrences(of: "yyyy", with: yyyyStr)
        result = result.replacingOccurrences(of: "yy", with: yyStr)
        result = result.replacingOccurrences(of: "MM", with: mmStr)
        result = result.replacingOccurrences(of: "dd", with: ddStr)

        // Normalize backslashes to forward slashes for uniform folder paths
        result = result.replacingOccurrences(of: "\\", with: "/")

        // Split into components to eliminate leading/trailing/duplicate slashes
        let parts = result.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.joined(separator: "/")
    }

    /// Formats current date as an example preview
    func examplePreview(for testPattern: String? = nil) -> String {
        let p = testPattern ?? pattern
        let preview = Self.format(date: Date(), in: .current, pattern: p)
        return preview.isEmpty ? "(Root)" : preview
    }
}
