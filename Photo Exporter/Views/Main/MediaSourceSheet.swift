//
//  MediaSourceSheet.swift
//  Photo Exporter
//

import SwiftUI
import AuthenticationServices

/// Sheet allowing the user to switch the list view source between Photo Library, a Local Folder,
/// a linked Google Drive folder, or a Samba share, as well as add/edit/delete Google Drive & Samba folders.
struct MediaSourceSheet: View {
    let currentSource: MediaSource
    let onSelectSource: (MediaSource) -> Void
    let onCancel: () -> Void

    @ObservedObject private var driveAuthService = GoogleDriveAuthService.shared
    @ObservedObject private var sambaService = SambaService.shared

    @State private var isSigningInGoogleDrive: Bool = false
    @State private var configuringGoogleDriveAccount: GoogleAccount? = nil
    @State private var isNewGoogleDriveAccount: Bool = false
    @State private var isShowingSambaConfig: Bool = false
    @State private var editingSambaDestination: SambaDestination? = nil
    @State private var isShowingLocalFolderPicker: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if let error = errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .padding(.horizontal, 16)
                    }

                    // Section 1: Media Sources
                    VStack(alignment: .leading, spacing: 10) {
                        Text("MEDIA SOURCE")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)

                        VStack(spacing: 10) {
                            // 1. Photo Library (default)
                            Button {
                                onSelectSource(.photoLibrary)
                            } label: {
                                DestinationCardView(
                                    icon: "photo.on.rectangle.angled",
                                    iconColor: .blue,
                                    title: "Photo Library",
                                    subtitle: "iPhone Photos & Videos",
                                    isSelected: currentSource == .photoLibrary
                                )
                            }
                            .buttonStyle(.plain)

                            // 2. Local Folder / Files
                            Button {
                                isShowingLocalFolderPicker = true
                            } label: {
                                let isLocalSelected: Bool = {
                                    if case .localFolder = currentSource { return true }
                                    return false
                                }()
                                let subtitle: String = {
                                    if case .localFolder(_, let path, let displayName) = currentSource {
                                        return "\(MediaSource.friendlyLocalFolderName(for: displayName)) (\(path))"
                                    }
                                    return "Browse Files, iCloud Drive, or device folder"
                                }()
                                DestinationCardView(
                                    icon: "folder.fill",
                                    iconColor: .blue,
                                    title: "Local Folder / Files",
                                    subtitle: subtitle,
                                    isSelected: isLocalSelected
                                )
                            }
                            .buttonStyle(.plain)

                            // 3. Linked Google Drive Folders (shared with ExportDestinationSheet)
                            ForEach(driveAuthService.accounts) { account in
                                let browsedAccount = driveAuthService.lastBrowsedAccount(for: account)
                                let isAccountSelected: Bool = {
                                    if case .googleDrive(let activeAccount) = currentSource {
                                        return activeAccount.id == account.id
                                    }
                                    return false
                                }()
                                Button {
                                    onSelectSource(.googleDrive(account: browsedAccount))
                                } label: {
                                    DestinationCardView(
                                        icon: "GoogleDriveIcon",
                                        isAssetIcon: true,
                                        iconColor: .green,
                                        title: account.name,
                                        subtitle: browsedAccount.gdrivePathDisplayString,
                                        isSelected: isAccountSelected,
                                        actionButtonTitle: "Edit",
                                        onAction: {
                                            configuringGoogleDriveAccount = account
                                            isNewGoogleDriveAccount = false
                                        }
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        configuringGoogleDriveAccount = account
                                        isNewGoogleDriveAccount = false
                                    } label: {
                                        Label("Edit Folder", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        withAnimation {
                                            driveAuthService.unlinkAccount(id: account.id)
                                        }
                                    } label: {
                                        Label("Delete Folder", systemImage: "trash")
                                    }
                                }
                            }

                            // 4. Saved Samba Shares (shared with ExportDestinationSheet)
                            ForEach(sambaService.destinations) { dest in
                                let browsedDest = sambaService.lastBrowsedDestination(for: dest)
                                let isDestSelected: Bool = {
                                    if case .samba(let activeDest) = currentSource {
                                        return activeDest.id == dest.id
                                    }
                                    return false
                                }()
                                Button {
                                    onSelectSource(.samba(destination: browsedDest))
                                } label: {
                                    DestinationCardView(
                                        icon: "server.rack",
                                        iconColor: .indigo,
                                        title: dest.name,
                                        subtitle: browsedDest.sharePathDisplayString,
                                        isSelected: isDestSelected,
                                        actionButtonTitle: "Edit",
                                        onAction: {
                                            editingSambaDestination = dest
                                        }
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        editingSambaDestination = dest
                                    } label: {
                                        Label("Edit Folder", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        withAnimation {
                                            sambaService.removeDestination(id: dest.id)
                                        }
                                    } label: {
                                        Label("Delete Folder", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    // Section 2: Add New Folder
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ADD NEW FOLDER")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)

                        VStack(spacing: 10) {
                            // Add Google Drive Folder
                            Button {
                                handleAddGoogleDriveTapped()
                            } label: {
                                addFolderCard(
                                    icon: "plus.circle.fill",
                                    color: .green,
                                    title: "Google Drive",
                                    subtitle: "Link a Google Drive folder",
                                    isLoading: isSigningInGoogleDrive
                                )
                            }
                            .buttonStyle(CardPressButtonStyle())
                            .disabled(isSigningInGoogleDrive)

                            // Add Samba Server
                            Button {
                                isShowingSambaConfig = true
                            } label: {
                                addFolderCard(
                                    icon: "plus.circle.fill",
                                    color: .indigo,
                                    title: "Samba Server",
                                    subtitle: "Connect to an SMB network share",
                                    isLoading: false
                                )
                            }
                            .buttonStyle(CardPressButtonStyle())
                        }
                        .padding(.horizontal, 16)
                    }

                    Spacer(minLength: 20)
                }
                .padding(.top, 16)
                .padding(.bottom, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Select Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            .sheet(isPresented: $isShowingLocalFolderPicker) {
                FolderPicker { url in
                    isShowingLocalFolderPicker = false
                    let isScoped = url.startAccessingSecurityScopedResource()
                    let bookmark = try? url.bookmarkData(
                        options: .minimalBookmark,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    if isScoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                    let displayName = MediaSource.friendlyLocalFolderName(for: url.lastPathComponent)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        onSelectSource(.localFolder(bookmarkData: bookmark, path: url.path, displayName: displayName))
                    }
                } onCancel: {
                    isShowingLocalFolderPicker = false
                }
            }
            .sheet(isPresented: $isShowingSambaConfig) {
                SambaConfigurationSheet()
            }
            .sheet(item: $editingSambaDestination) { dest in
                SambaConfigurationSheet(existingDestination: dest)
            }
            .sheet(item: $configuringGoogleDriveAccount) { account in
                GoogleDriveConfigurationSheet(
                    account: account,
                    isNew: isNewGoogleDriveAccount,
                    onSave: { _ in
                        isNewGoogleDriveAccount = false
                        configuringGoogleDriveAccount = nil
                    },
                    onCancel: {
                        if isNewGoogleDriveAccount {
                            driveAuthService.unlinkAccount(id: account.id)
                        }
                        isNewGoogleDriveAccount = false
                        configuringGoogleDriveAccount = nil
                    }
                )
            }
        }
    }

    private func addFolderCard(
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        isLoading: Bool
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color.opacity(0.12))
                    .frame(width: 44, height: 44)

                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .tint(color)
            } else {
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
                .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5)
        )
    }

    private func handleAddGoogleDriveTapped() {
        guard !isSigningInGoogleDrive else { return }
        Task {
            await MainActor.run {
                isSigningInGoogleDrive = true
                errorMessage = nil
            }
            do {
                let newAccount = try await driveAuthService.signIn(defaultName: "Google Drive")
                await MainActor.run {
                    isSigningInGoogleDrive = false
                    configuringGoogleDriveAccount = newAccount
                    isNewGoogleDriveAccount = true
                }
            } catch {
                await MainActor.run {
                    isSigningInGoogleDrive = false
                    let nsErr = error as NSError
                    if nsErr.domain == ASWebAuthenticationSessionError.errorDomain,
                       nsErr.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        return
                    }
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

