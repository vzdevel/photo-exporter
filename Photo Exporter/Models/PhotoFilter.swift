//
//  PhotoFilter.swift
//  Photo Exporter
//

import Foundation
import SwiftUI

/// Available global media type filters
enum MediaTypeFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case photos = "Photos"
    case videos = "Videos"
    case screenshots = "Screenshots"

    var id: String { rawValue }

    var title: String { rawValue }

    var iconName: String {
        switch self {
        case .all:
            return "photo.stack"
        case .photos:
            return "photo"
        case .videos:
            return "video"
        case .screenshots:
            return "camera.viewfinder"
        }
    }
}

/// Available filter options for photo library view
enum PhotoFilter: String, CaseIterable, Identifiable {
    case all = "All Photos"
    case inferred = "Inferred"
    case adjusted = "Adjusted"
    case drifted = "Drifted"
    case edited = "Edited"
    case savedFromOtherApps = "From Other Apps"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All Photos"
        case .inferred:
            return "Inferred"
        case .adjusted:
            return "Adjusted"
        case .drifted:
            return "Drifted"
        case .edited:
            return "Edited"
        case .savedFromOtherApps:
            return "Saved from Other Apps"
        }
    }

    var shortTitle: String {
        switch self {
        case .all:
            return "All"
        case .inferred:
            return "Inferred"
        case .adjusted:
            return "Adjusted"
        case .drifted:
            return "Drifted"
        case .edited:
            return "Edited"
        case .savedFromOtherApps:
            return "From Apps"
        }
    }

    var iconName: String? {
        switch self {
        case .all:
            return "photo.stack"
        case .inferred:
            return nil
        case .adjusted:
            return nil
        case .drifted:
            return nil
        case .edited:
            return nil
        case .savedFromOtherApps:
            return nil
        }
    }

    var description: String {
        switch self {
        case .all:
            return "All photos in your library"
        case .inferred:
            return "Photos and videos with inferred timezone (no embedded timezone and no adjusted date, time, or timezone)"
        case .adjusted:
            return "Photos whose date, time, timezone, or GPS location was adjusted in iOS Photos"
        case .drifted:
            return "Videos whose CreateDate or ModifyDate differs by more than 5 minutes from CreationDate"
        case .edited:
            return "Photos with edit adjustments (e.g. crop, filter, markup) in Photos"
        case .savedFromOtherApps:
            return "Photos saved from third-party apps, web, or messaging"
        }
    }

    static let subtlePurple = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.72, green: 0.46, blue: 0.91, alpha: 1.0)
                : UIColor(red: 0.61, green: 0.36, blue: 0.80, alpha: 1.0)
        }
    )

    var color: Color {
        switch self {
        case .all:
            return .blue
        case .inferred:
            return .indigo
        case .adjusted:
            return .orange
        case .drifted:
            return .red
        case .edited:
            return PhotoFilter.subtlePurple
        case .savedFromOtherApps:
            return .teal
        }
    }
}
