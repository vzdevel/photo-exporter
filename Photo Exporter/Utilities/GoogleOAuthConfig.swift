//
//  GoogleOAuthConfig.swift
//  Photo Exporter
//
//  Loads Google OAuth 2.0 iOS client configuration from GoogleService-Info.plist.
//

import Foundation

enum GoogleOAuthConfig {
    private static let plistValues: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return [:]
        }
        return dict
    }()

    static var clientID: String {
        (plistValues["CLIENT_ID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var reversedClientID: String {
        let explicit = (plistValues["REVERSED_CLIENT_ID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !explicit.isEmpty {
            return explicit
        }
        let parts = clientID.split(separator: ".")
        guard !parts.isEmpty else { return "" }
        return parts.reversed().joined(separator: ".")
    }

    static var redirectURI: String {
        guard !reversedClientID.isEmpty else { return "" }
        return "\(reversedClientID):/oauth2redirect"
    }

    static var callbackURLScheme: String {
        reversedClientID
    }

    static var isConfigured: Bool {
        !clientID.isEmpty &&
        !reversedClientID.isEmpty &&
        !clientID.contains("YOUR_IOS_CLIENT_ID") &&
        !reversedClientID.contains("YOUR_IOS_CLIENT_ID")
    }
}
