//
//  GoogleDriveConfigurationSheet.swift
//  Photo Exporter
//

import SwiftUI

/// Configuration sheet for adding or editing a Google Drive export destination.
/// Displays user email, configures destination name, opens the shared folder selection sheet, and allows deleting the destination.
struct GoogleDriveConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let account: GoogleAccount
    var isNew: Bool = false
    var onSave: ((GoogleAccount) -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    @ObservedObject private var authService = GoogleDriveAuthService.shared

    @State private var name: String = ""
    @State private var email: String = ""
    @State private var isFetchingEmail: Bool = false
    @State private var isReauthenticating: Bool = false
    @State private var authErrorMessage: String? = nil

    // Target folder selection state
    @State private var selectedFolderId: String = "root"
    @State private var selectedFolderName: String = "My Drive"
    @State private var selectedFolderPath: String = "My Drive"
    @State private var selectedFolderBreadcrumbs: [GoogleDriveFolderBreadcrumb] = []
    @State private var isShowingFolderPicker: Bool = false

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                // Section 1: Account Info & Destination Name
                Section("Account Information") {
                    HStack {
                        Text("Email")
                        Spacer()
                        if isFetchingEmail {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else if !email.isEmpty {
                            Text(email)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("Signed In")
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Destination Name")
                        TextField("Google Drive", text: $name)
                            .multilineTextAlignment(.trailing)
                    }

                    if !isNew {
                        Button {
                            reauthenticateAccount()
                        } label: {
                            HStack {
                                Label("Sign In Again", systemImage: "person.badge.key")
                                Spacer()
                                if isReauthenticating {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                }
                            }
                        }
                        .disabled(isReauthenticating)

                        if let authErrorMessage {
                            Text(authErrorMessage)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }

                // Section 2: Selected Target Folder Summary
                Section("Configured Export Folder") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Target Destination")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill.badge.checkmark")
                                .font(.system(size: 18))
                                .foregroundColor(.green)

                            Text(cleanPath(selectedFolderPath))
                                .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.vertical, 2)

                    Button {
                        isShowingFolderPicker = true
                    } label: {
                        HStack {
                            Label("Select Export Folder", systemImage: "folder.badge.gearshape")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Section 3: Delete Destination
                Section {
                    Button(role: .destructive) {
                        authService.unlinkAccount(id: account.id)
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "trash")
                            Text("Delete Destination")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Google Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel?()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveConfiguration()
                    }
                    .bold()
                    .disabled(!isValid)
                }
            }
            .sheet(isPresented: $isShowingFolderPicker) {
                RemoteFolderSelectionSheet(
                    mode: .googleDrive(
                        accountID: account.id,
                        initialFolderId: selectedFolderId,
                        initialFolderName: selectedFolderName,
                        initialFolderPath: selectedFolderPath,
                        initialBreadcrumbs: selectedFolderBreadcrumbs
                    )
                ) { selection in
                    if case let .googleDrive(folderId, folderName, folderPath, breadcrumbs) = selection {
                        selectedFolderId = folderId
                        selectedFolderName = folderName
                        selectedFolderPath = folderPath
                        selectedFolderBreadcrumbs = breadcrumbs
                    }
                }
            }
            .onAppear {
                initializeState()
            }
            .task {
                await fetchEmailIfNeeded()
                await resolveHierarchyIfNeeded()
            }
        }
    }

    // MARK: - Helpers

    private func reauthenticateAccount() {
        isReauthenticating = true
        authErrorMessage = nil

        Task {
            do {
                let updated = try await authService.reauthenticate(accountID: account.id)
                await MainActor.run {
                    if let updatedEmail = updated.email, !updatedEmail.isEmpty {
                        self.email = updatedEmail
                    }
                    self.isReauthenticating = false
                }
                await resolveHierarchyIfNeeded()
            } catch {
                await MainActor.run {
                    self.isReauthenticating = false
                    let nsError = error as NSError
                    // ASWebAuthenticationSessionError.canceledLogin (code 1)
                    if !(nsError.domain == "com.apple.AuthenticationServices.WebAuthenticationSession" && nsError.code == 1) {
                        self.authErrorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func cleanPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.isEmpty ? "My Drive" : trimmed
    }

    private func initializeState() {
        name = account.name
        email = account.email ?? ""
        selectedFolderId = account.targetFolderId
        selectedFolderName = account.targetFolderName
        selectedFolderPath = account.folderPath.isEmpty ? account.targetFolderName : account.folderPath
        selectedFolderBreadcrumbs = account.folderBreadcrumbs
    }

    private func resolveHierarchyIfNeeded() async {
        guard selectedFolderId != "root" && selectedFolderBreadcrumbs.isEmpty else { return }
        if let resolved = await GoogleDriveService.shared.resolveFolderHierarchy(for: selectedFolderId, accountID: account.id) {
            await MainActor.run {
                if self.selectedFolderId == self.account.targetFolderId && self.selectedFolderBreadcrumbs.isEmpty {
                    self.selectedFolderBreadcrumbs = resolved
                }
            }
        }
    }

    private func fetchEmailIfNeeded() async {
        if email.isEmpty {
            isFetchingEmail = true
            if let fetched = await authService.fetchAccountEmail(for: account.id) {
                await MainActor.run {
                    self.email = fetched
                }
            }
            await MainActor.run {
                self.isFetchingEmail = false
            }
        }
    }

    private func saveConfiguration() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "Google Drive" : trimmedName

        let breadcrumbs: [GoogleDriveFolderBreadcrumb]
        if !selectedFolderBreadcrumbs.isEmpty {
            breadcrumbs = selectedFolderBreadcrumbs
        } else if selectedFolderId == "root" {
            breadcrumbs = [GoogleDriveFolderBreadcrumb(id: "root", name: "My Drive")]
        } else {
            breadcrumbs = [
                GoogleDriveFolderBreadcrumb(id: "root", name: "My Drive"),
                GoogleDriveFolderBreadcrumb(id: selectedFolderId, name: selectedFolderName)
            ]
        }

        authService.updateAccount(
            id: account.id,
            name: finalName,
            email: email.isEmpty ? nil : email,
            folderId: selectedFolderId,
            folderName: selectedFolderName,
            folderPath: selectedFolderPath,
            folderBreadcrumbs: breadcrumbs
        )

        var updated = account
        updated.name = finalName
        if !email.isEmpty {
            updated.email = email
        }
        updated.folderId = selectedFolderId
        updated.folderName = selectedFolderName
        updated.folderPath = selectedFolderPath
        updated.folderBreadcrumbs = breadcrumbs

        onSave?(updated)
        dismiss()
    }
}

