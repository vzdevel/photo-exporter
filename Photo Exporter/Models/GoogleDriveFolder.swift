//
//  GoogleDriveFolder.swift
//  Photo Exporter
//

import Foundation

/// Representation of a Google Drive folder or file item
struct GoogleDriveFolder: Identifiable, Hashable {
    let id: String
    let name: String
    let modifiedTime: Date?

    init(id: String, name: String, modifiedTime: Date? = nil) {
        self.id = id
        self.name = name
        self.modifiedTime = modifiedTime
    }
}

