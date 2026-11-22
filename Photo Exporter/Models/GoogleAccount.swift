//
//  GoogleAccount.swift
//  Photo Exporter
//

import Foundation

/// Represents a breadcrumb node in Google Drive folder navigation hierarchy
struct GoogleDriveFolderBreadcrumb: Identifiable, Codable, Hashable {
    var id: String
    var name: String
}

/// Represents a linked Google account (Drive or Photos) with OAuth 2.0 credentials
struct GoogleAccount: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var email: String? = nil
    var folderId: String = "root"
    var folderName: String = "My Drive"
    var folderPath: String = "My Drive"
    var folderBreadcrumbs: [GoogleDriveFolderBreadcrumb] = []
    var accessToken: String
    var refreshToken: String
    var tokenExpiry: Date
    var addedDate: Date = Date()

    var targetFolderId: String {
        let trimmed = folderId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "root" : trimmed
    }

    var targetFolderName: String {
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "My Drive" : trimmed
    }

    var gdrivePathDisplayString: String {
        let clean = folderPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return clean.isEmpty ? "My Drive" : clean
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case email
        case folderId
        case folderName
        case folderPath
        case folderBreadcrumbs
        case accessToken
        case refreshToken
        case tokenExpiry
        case addedDate
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        email: String? = nil,
        folderId: String = "root",
        folderName: String = "My Drive",
        folderPath: String = "My Drive",
        folderBreadcrumbs: [GoogleDriveFolderBreadcrumb] = [],
        accessToken: String,
        refreshToken: String,
        tokenExpiry: Date,
        addedDate: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.folderId = folderId
        self.folderName = folderName
        self.folderPath = folderPath
        self.folderBreadcrumbs = folderBreadcrumbs
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenExpiry = tokenExpiry
        self.addedDate = addedDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        let decodedEmail = try container.decodeIfPresent(String.self, forKey: .email)
        self.email = decodedEmail
        if let decodedName = try container.decodeIfPresent(String.self, forKey: .name), !decodedName.isEmpty {
            self.name = decodedName
        } else if let legacy = decodedEmail, !legacy.isEmpty {
            self.name = legacy
        } else {
            self.name = "Google Account"
        }
        self.folderId = try container.decodeIfPresent(String.self, forKey: .folderId) ?? "root"
        self.folderName = try container.decodeIfPresent(String.self, forKey: .folderName) ?? "My Drive"
        self.folderPath = try container.decodeIfPresent(String.self, forKey: .folderPath) ?? "My Drive"
        self.folderBreadcrumbs = try container.decodeIfPresent([GoogleDriveFolderBreadcrumb].self, forKey: .folderBreadcrumbs) ?? []
        self.accessToken = try container.decode(String.self, forKey: .accessToken)
        self.refreshToken = try container.decode(String.self, forKey: .refreshToken)
        self.tokenExpiry = try container.decode(Date.self, forKey: .tokenExpiry)
        self.addedDate = try container.decodeIfPresent(Date.self, forKey: .addedDate) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encode(folderId, forKey: .folderId)
        try container.encode(folderName, forKey: .folderName)
        try container.encode(folderPath, forKey: .folderPath)
        try container.encode(folderBreadcrumbs, forKey: .folderBreadcrumbs)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encode(refreshToken, forKey: .refreshToken)
        try container.encode(tokenExpiry, forKey: .tokenExpiry)
        try container.encode(addedDate, forKey: .addedDate)
    }
}
