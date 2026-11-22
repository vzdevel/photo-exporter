//
//  ExportDestinationSheet.swift
//  Photo Exporter
//

import SwiftUI
import AuthenticationServices
import Photos

/// Sheet presented upon tapping Export, letting the user choose between Valid Destinations (Local, linked Google Drive accounts, Samba shares) and Add New Destination
struct ExportDestinationSheet: View {
    let itemCount: Int
    var showProcessingInfo: Bool = false
    var renameGroups: [FileRenameGroup] = []
    var renamedFiles: [FileRenameItem] = []
    let onSelectLocal: () -> Void
    let onSelectGoogleDrive: (GoogleAccount) -> Void
    let onSelectGooglePhotos: (GoogleAccount) -> Void
    let onSelectSamba: (SambaDestination) -> Void
    let onCancel: () -> Void

    @ObservedObject private var driveAuthService = GoogleDriveAuthService.shared
    @ObservedObject private var photosAuthService = GooglePhotosAuthService.shared
    @ObservedObject private var sambaService = SambaService.shared
    @ObservedObject private var folderSettings = FolderOrganizationSettings.shared

    @State private var isSigningInGoogleDrive: Bool = false
    @State private var isSigningInGooglePhotos: Bool = false
    @State private var configuringGoogleDriveAccount: GoogleAccount? = nil
    @State private var isNewGoogleDriveAccount: Bool = false
    @State private var isShowingSambaConfig: Bool = false
    @State private var editingSambaDestination: SambaDestination? = nil
    @State private var errorMessage: String? = nil
    @State private var isShowingRenameDialog: Bool = false
    @State private var renameTargetAccountID: String = ""
    @State private var renameTargetIsPhotos: Bool = false
    @State private var destinationNameInput: String = ""
    @State private var isShowingExportInfoSheet: Bool = false
    @State private var pendingUnlinkPhotosAccount: GoogleAccount? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    // Error banner if any
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

                    // Section 0: Organize Into Folders
                    folderOrganizationSection

                    // Section 1: Choose Destination
                    VStack(alignment: .leading, spacing: 10) {
                        Text("CHOOSE DESTINATION")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)

                        VStack(spacing: 10) {
                            // 1. Local Device / Files
                            Button(action: onSelectLocal) {
                                DestinationCardView(
                                    icon: "folder.fill",
                                    iconColor: .blue,
                                    title: "Local Folder / Files",
                                    subtitle: "Save to Files, iCloud Drive, or device storage"
                                )
                            }
                            .buttonStyle(.plain)

                            // 2. Linked Google Drive Accounts
                            ForEach(driveAuthService.accounts) { account in
                                Button {
                                    onSelectGoogleDrive(account)
                                } label: {
                                    DestinationCardView(
                                        icon: "GoogleDriveIcon",
                                        isAssetIcon: true,
                                        iconColor: .green,
                                        title: account.name,
                                        subtitle: account.gdrivePathDisplayString,
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
                                        Label("Edit Destination", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        withAnimation {
                                            driveAuthService.unlinkAccount(id: account.id)
                                        }
                                    } label: {
                                        Label("Delete Destination", systemImage: "trash")
                                    }
                                }
                            }

                            // 3. Linked Google Photos Accounts
                            ForEach(photosAuthService.accounts) { account in
                                Button {
                                    onSelectGooglePhotos(account)
                                } label: {
                                    DestinationCardView(
                                        icon: "GooglePhotosIcon",
                                        isAssetIcon: true,
                                        iconColor: .red,
                                        title: account.name,
                                        subtitle: "Google Photos Account",
                                        actionButtonTitle: "Unlink",
                                        onAction: {
                                            pendingUnlinkPhotosAccount = account
                                        }
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        promptRename(account: account, isPhotos: true)
                                    } label: {
                                        Label("Rename Destination", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        pendingUnlinkPhotosAccount = account
                                    } label: {
                                        Label("Unlink Account", systemImage: "person.badge.minus")
                                    }
                                }
                            }

                            // 4. Configured Samba Destinations
                            ForEach(sambaService.destinations) { dest in
                                Button {
                                    onSelectSamba(dest)
                                } label: {
                                    DestinationCardView(
                                        icon: "server.rack",
                                        iconColor: .indigo,
                                        title: dest.displayName,
                                        subtitle: dest.sharePathDisplayString,
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
                                        Label("Edit Destination", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        withAnimation {
                                            sambaService.removeDestination(id: dest.id)
                                        }
                                    } label: {
                                        Label("Delete Destination", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    // Section 2: Add New Destination
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ADD DESTINATION")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)

                        VStack(spacing: 10) {
                            // Add Google Drive Account
                            Button {
                                handleAddGoogleDriveTapped()
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(Color.green.opacity(0.12))
                                            .frame(width: 44, height: 44)

                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 22))
                                            .foregroundColor(.green)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Google Drive")
                                            .font(.headline)
                                            .foregroundColor(.primary)

                                        Text("Link a Google Drive account")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    if isSigningInGoogleDrive {
                                        ProgressView()
                                            .tint(.green)
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
                            .buttonStyle(CardPressButtonStyle())
                            .disabled(isSigningInGoogleDrive)

                            // Add Google Photos Account
                            Button {
                                handleAddGooglePhotosTapped()
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(Color.red.opacity(0.12))
                                            .frame(width: 44, height: 44)

                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 22))
                                            .foregroundColor(.red)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Google Photos")
                                            .font(.headline)
                                            .foregroundColor(.primary)

                                        Text("Link a Google Photos account")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    if isSigningInGooglePhotos {
                                        ProgressView()
                                            .tint(.red)
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
                            .buttonStyle(CardPressButtonStyle())
                            .disabled(isSigningInGooglePhotos)

                            // Add Samba Server
                            Button {
                                isShowingSambaConfig = true
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(Color.indigo.opacity(0.12))
                                            .frame(width: 44, height: 44)

                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 22))
                                            .foregroundColor(.indigo)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Samba Server")
                                            .font(.headline)
                                            .foregroundColor(.primary)

                                        Text("Connect to an SMB network share")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(Color(.tertiaryLabel))
                                }
                                .padding(14)
                                .background(Color(.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5)
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }

                ToolbarItem(placement: .principal) {
                    HStack(spacing: 5) {
                        Text(itemCount == 1 ? "Export 1 item" : "Export \(itemCount) items")
                            .font(.headline)

                        if showProcessingInfo {
                            Button {
                                isShowingExportInfoSheet = true
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundColor(.secondary)
                            }
                            .accessibilityLabel("Export Processing Info")
                        }
                    }
                }
            }
            .sheet(isPresented: $isShowingExportInfoSheet) {
                ExportProcessingInfoSheet()
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
            .alert(
                renameTargetIsPhotos ? "Name Google Photos Destination" : "Name Google Drive Destination",
                isPresented: $isShowingRenameDialog
            ) {
                TextField("Destination Name", text: $destinationNameInput)
                Button("Save") {
                    applyRenamedDestination()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(renameTargetIsPhotos ? "Enter a destination name (default: Google Photos)" : "Enter a destination name (default: Google Drive)")
            }
            .alert(
                "Unlink Google Photos?",
                isPresented: Binding(
                    get: { pendingUnlinkPhotosAccount != nil },
                    set: { if !$0 { pendingUnlinkPhotosAccount = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    pendingUnlinkPhotosAccount = nil
                }
                Button("Unlink", role: .destructive) {
                    if let account = pendingUnlinkPhotosAccount {
                        pendingUnlinkPhotosAccount = nil
                        withAnimation {
                            photosAuthService.unlinkAccount(id: account.id)
                        }
                    }
                }
            } message: {
                if let account = pendingUnlinkPhotosAccount {
                    Text("Are you sure you want to unlink \"\(account.name)\"?")
                }
            }
        }
    }

    // MARK: - Folder Organization Section

    @ViewBuilder
    private var patternFloatingTrailingView: some View {
        if let invalidChar = FolderOrganizationSettings.firstInvalidCharacter(in: folderSettings.pattern) {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Text("'\(String(invalidChar))' not supported")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        } else {
            HStack(spacing: 3) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(folderSettings.examplePreview())
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var folderOrganizationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ORGANIZE INTO FOLDERS")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 20)

            VStack(spacing: 12) {
                Toggle(isOn: $folderSettings.isEnabled.animation(.spring(response: 0.3, dampingFraction: 0.8))) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.orange.opacity(0.12))
                                .frame(width: 36, height: 36)
                            Image(systemName: "folder.badge.gearshape")
                                .font(.system(size: 18))
                                .foregroundColor(.orange)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Organize Photos by Date")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.primary)

                            Text("Applies to Local, Google Drive and Samba")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .tint(.blue)

                if folderSettings.isEnabled {
                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("Pattern:")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)

                            HStack(spacing: 8) {
                                TextField("e.g. yyyy/MM", text: $folderSettings.pattern)
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .textInputAutocapitalization(.never)
                                    .disableAutocorrection(true)

                                patternFloatingTrailingView
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        HStack(spacing: 8) {
                            ForEach(["yyyy", "yyyyMM", "yyMM", "yyyy-MM", "yyyy/MM"], id: \.self) { preset in
                                Button {
                                    folderSettings.pattern = preset
                                } label: {
                                    Text(preset)
                                        .font(.system(size: 12, weight: folderSettings.pattern == preset ? .semibold : .regular, design: .monospaced))
                                        .foregroundColor(folderSettings.pattern == preset ? .white : .primary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(folderSettings.pattern == preset ? Color.blue : Color(.tertiarySystemGroupedBackground))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5)
            )
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Actions

    private func promptRename(account: GoogleAccount, isPhotos: Bool) {
        renameTargetAccountID = account.id
        renameTargetIsPhotos = isPhotos
        destinationNameInput = account.name
        isShowingRenameDialog = true
    }

    private func applyRenamedDestination() {
        let trimmed = destinationNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if renameTargetIsPhotos {
            photosAuthService.updateAccountName(id: renameTargetAccountID, newName: trimmed)
        } else {
            driveAuthService.updateAccountName(id: renameTargetAccountID, newName: trimmed)
        }
    }

    private func handleAddGoogleDriveTapped() {
        guard !isSigningInGoogleDrive && !isSigningInGooglePhotos else { return }
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

    private func handleAddGooglePhotosTapped() {
        guard !isSigningInGoogleDrive && !isSigningInGooglePhotos else { return }
        Task {
            await MainActor.run {
                isSigningInGooglePhotos = true
                errorMessage = nil
            }

            do {
                let newAccount = try await photosAuthService.signIn(defaultName: "Google Photos")
                await MainActor.run {
                    isSigningInGooglePhotos = false
                    promptRename(account: newAccount, isPhotos: true)
                }
            } catch {
                await MainActor.run {
                    isSigningInGooglePhotos = false
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

// MARK: - Card Press Button Style

struct CardPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}
