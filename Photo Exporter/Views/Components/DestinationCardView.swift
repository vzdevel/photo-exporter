//
//  DestinationCardView.swift
//  Photo Exporter
//

import SwiftUI

/// Renders either a bundled asset icon or an SF Symbol icon at a consistent visual size.
struct AppSourceIconView: View {
    let iconName: String
    var isAssetImage: Bool = false
    var size: CGFloat = 22
    var weight: Font.Weight = .regular
    var color: Color = .primary

    var body: some View {
        if isAssetImage {
            Image(iconName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: iconName)
                .font(.system(size: size, weight: weight))
                .foregroundColor(color)
        }
    }
}

/// Reusable card view shared by ExportDestinationSheet and MediaSourceSheet
struct DestinationCardView: View {
    let icon: String
    var isAssetIcon: Bool = false
    let iconColor: Color
    let title: String
    let subtitle: String
    var isSelected: Bool = false
    var actionButtonTitle: String? = nil
    var onAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 46, height: 46)

                AppSourceIconView(
                    iconName: icon,
                    isAssetImage: isAssetIcon,
                    size: isAssetIcon ? 28 : 22,
                    color: iconColor
                )
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                if let actionTitle = actionButtonTitle, let onAction = onAction {
                    let isDestructive = actionTitle == "Unlink"
                    Button(role: isDestructive ? .destructive : nil, action: onAction) {
                        Text(actionTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(isDestructive ? .red : .primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(isDestructive ? Color.red.opacity(0.12) : Color(.tertiarySystemFill))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(.tertiaryLabel))
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Color.blue.opacity(0.6) : Color(.separator).opacity(0.4), lineWidth: isSelected ? 1.2 : 0.5)
        )
    }
}

