//
//  ExportProcessingInfoSheet.swift
//  Photo Exporter
//

import SwiftUI

struct ExportProcessingInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    infoRow(
                        title: "No Labels",
                        icon: "photo",
                        iconColor: .secondary,
                        description: "Exported as the exact original file without re-encoding or modifying metadata."
                    )

                    badgeRow(
                        type: .otherApp,
                        title: "Saved from Another App",
                        description: "Exported unmodified as the original file unless other adjustment labels are also present."
                    )
                } header: {
                    Text("Original Unmodified")
                }

                Section {
                    badgeRow(
                        type: .adjustedDate,
                        title: "Adjusted Date & Time",
                        description: "Embeds the adjusted date, time, and timezone into the exported file's EXIF or QuickTime metadata."
                    )

                    badgeRow(
                        type: .adjustedGPS,
                        title: "Adjusted Location",
                        description: "Embeds the adjusted GPS coordinates into the exported file's EXIF or QuickTime metadata."
                    )

                    badgeRow(
                        type: .inferred,
                        title: "Inferred Timezone",
                        description: "Original metadata had no timezone offset. Embeds the inferred timezone into the exported file's EXIF or QuickTime metadata."
                    )

                    badgeRow(
                        type: .drifted,
                        title: "Drifted Video Timestamps",
                        description: "Video container CreateDate / ModifyDate differ from its embedded creation date. Aligns them with the creation date on export."
                    )
                } header: {
                    Text("Metadata Updates")
                }

                Section {
                    badgeRow(
                        type: .edited,
                        title: "Edited Media",
                        description: "Has Photos app edits (crop, filters, adjustments). Exports the rendered edited version with edits applied, along with any metadata updates."
                    )
                } header: {
                    Text("Rendered Edits")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Export Processing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func badgeRow(type: StatusBadgeView.BadgeType, title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusBadgeView(type: type)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
            }

            Text(description)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func infoRow(title: String, icon: String, iconColor: Color, description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(iconColor)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
            }

            Text(description)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

