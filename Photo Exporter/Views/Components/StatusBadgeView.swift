//
//  StatusBadgeView.swift
//  Photo Exporter
//

import SwiftUI

struct StatusBadgeView: View {
    enum BadgeType: Equatable {
        case adjustedDate
        case adjustedGPS
        case adjustedRotation
        case adjusted
        case inferred
        case drifted
        case otherApp
        case edited

        var title: String {
            switch self {
            case .adjustedDate, .adjustedGPS, .adjustedRotation, .adjusted:
                return "Adjusted"
            case .inferred:
                return "Inferred"
            case .drifted:
                return "Drifted"
            case .otherApp:
                return "From App"
            case .edited:
                return "Edited"
            }
        }

        var iconName: String {
            switch self {
            case .adjustedDate:
                return "calendar.badge.clock" // time icon
            case .adjustedGPS:
                return "mappin.and.ellipse"   // location / maps marker icon
            case .adjustedRotation:
                return "rotate.right"
            case .adjusted:
                return "calendar.badge.clock"
            case .inferred:
                return "globe"
            case .drifted:
                return "clock.badge.exclamationmark"
            case .otherApp:
                return "arrow.down.app"
            case .edited:
                return "slider.horizontal.3"
            }
        }

        var color: Color {
            switch self {
            case .adjustedDate, .adjustedGPS, .adjustedRotation, .adjusted:
                return .orange
            case .inferred:
                return .indigo
            case .drifted:
                return PhotoFilter.drifted.color
            case .otherApp:
                return .teal
            case .edited:
                return PhotoFilter.edited.color
            }
        }
    }

    let type: BadgeType
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: type.iconName)
                .font(.system(size: compact ? 9 : 11, weight: .semibold))

            if !compact {
                Text(type.title)
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, compact ? 2 : 4)
        .background(type.color.opacity(0.15))
        .foregroundColor(type.color)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(type.color.opacity(0.3), lineWidth: 0.8)
        )
    }
}
