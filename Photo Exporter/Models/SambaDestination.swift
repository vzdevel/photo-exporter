//
//  SambaDestination.swift
//  Photo Exporter
//

import Foundation

/// Represents a configured Samba (SMB/CIFS) network share destination
struct SambaDestination: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var host: String
    var port: Int = 445
    var share: String
    var path: String = ""
    var isGuest: Bool = false
    var username: String = ""
    var password: String = ""
    var addedDate: Date = Date()

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return host
    }

    var sharePathDisplayString: String {
        let cleanShare = share.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let portPart = port == 445 ? "" : ":\(port)"
        if cleanShare.isEmpty {
            return "\(host)\(portPart)"
        }
        var cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !cleanPath.isEmpty {
            cleanPath = "/" + cleanPath
        }
        return "\(host)\(portPart)/\(cleanShare)\(cleanPath)"
    }
}

