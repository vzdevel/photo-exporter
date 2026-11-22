//
//  SambaConfigurationSheet.swift
//  Photo Exporter
//

import SwiftUI

/// Configuration sheet for adding or editing a Samba (SMB) network share destination
struct SambaConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss

    var existingDestination: SambaDestination? = nil
    var onSave: ((SambaDestination) -> Void)? = nil

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: Int = 445
    @State private var share: String = ""
    @State private var path: String = ""
    @State private var isGuest: Bool = false
    @State private var username: String = ""
    @State private var password: String = ""

    // Testing & folder picker state
    @State private var isTesting: Bool = false
    @State private var testResult: (isSuccess: Bool, message: String)? = nil
    @State private var isShowingFolderPicker: Bool = false

    private var canBrowseFolders: Bool {
        let hasHost = !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPort = port > 0 && port <= 65535
        let hasAuth = isGuest || !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasHost && hasPort && hasAuth
    }

    private var isValid: Bool {
        let hasShare = !share.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return canBrowseFolders && hasShare
    }

    private var formattedConfiguredPath: String? {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanShare = share.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        guard !cleanShare.isEmpty else { return nil }
        let cleanSubpath = path.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        let hostSegment = cleanHost.isEmpty ? "server" : cleanHost
        if cleanSubpath.isEmpty {
            return "\(hostSegment)/\(cleanShare)"
        }
        return "\(hostSegment)/\(cleanShare)/\(cleanSubpath)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server Information") {
                    TextField("Server Name / Label (e.g. Home NAS)", text: $name)

                    TextField("Server Host or IP (e.g. 192.168.1.100)", text: $host)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)

                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("445", value: $port, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }

                Section("Authentication") {
                    Toggle("Guest / Anonymous Access", isOn: $isGuest.animation())

                    if !isGuest {
                        TextField("Username", text: $username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        SecureField("Password", text: $password)
                    }
                }

                Section {
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .padding(.trailing, 4)
                                Text("Connecting...")
                            } else {
                                Image(systemName: "network")
                                    .foregroundColor(.blue)
                                Text("Test Connection")
                                    .fontWeight(.medium)
                            }
                        }
                    }
                    .disabled(isTesting || !canBrowseFolders)

                    if let result = testResult {
                        HStack(spacing: 8) {
                            Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(result.isSuccess ? .green : .red)
                            Text(result.message)
                                .font(.footnote)
                                .foregroundColor(result.isSuccess ? .green : .red)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Connection Verification")
                }

                Section {
                    if let configuredPath = formattedConfiguredPath {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Target Destination")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack(spacing: 8) {
                                Image(systemName: "folder.fill.badge.checkmark")
                                    .font(.system(size: 18))
                                    .foregroundColor(.green)

                                Text(configuredPath)
                                    .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(.vertical, 2)
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.badge.questionmark")
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                            Text("No export folder selected")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }

                    Button {
                        isShowingFolderPicker = true
                    } label: {
                        HStack {
                            Label(formattedConfiguredPath == nil ? "Select Export Folder" : "Edit Export Folder", systemImage: "folder.badge.gearshape")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(!canBrowseFolders)
                } header: {
                    Text("Configured Export Folder")
                } footer: {
                    if canBrowseFolders {
                        Text("Browse shares on the server and pick a share or subfolder as your export folder.")
                    } else {
                        Text("Enter the server host, port, and authentication details above before selecting an export folder.")
                    }
                }

                if let existing = existingDestination {
                    Section {
                        Button(role: .destructive) {
                            SambaService.shared.removeDestination(id: existing.id)
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
            }
            .navigationTitle(existingDestination == nil ? "Add Samba Server" : "Edit Samba Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveDestination()
                    }
                    .bold()
                    .disabled(!isValid || isTesting)
                }
            }
            .sheet(isPresented: $isShowingFolderPicker) {
                RemoteFolderSelectionSheet(
                    mode: .samba(
                        host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                        port: port,
                        isGuest: isGuest,
                        username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                        password: password,
                        initialShare: share,
                        initialPath: path
                    )
                ) { selection in
                    if case let .samba(selectedShare, selectedPath) = selection {
                        share = selectedShare
                        path = selectedPath
                        testResult = nil
                    }
                }
            }
            .onAppear {
                if let existing = existingDestination {
                    name = existing.name
                    host = existing.host
                    port = existing.port
                    share = existing.share
                    path = existing.path
                    isGuest = existing.isGuest
                    username = existing.username
                    password = existing.password
                }
            }
        }
    }

    private func testConnection() {
        let dest = buildDestination()
        Task {
            await MainActor.run {
                isTesting = true
                testResult = nil
            }

            do {
                let shares: [String]
                if dest.share.isEmpty {
                    shares = try await SambaService.shared.listShares(for: dest)
                } else {
                    _ = try await SambaService.shared.testConnection(to: dest)
                    shares = (try? await SambaService.shared.listShares(for: dest)) ?? []
                }

                let message: String
                if dest.share.isEmpty {
                    if shares.isEmpty {
                        message = "Connected and authenticated with \(dest.host):\(dest.port). No visible shares were found."
                    } else {
                        message = "Connected and authenticated with \(dest.host):\(dest.port). Available shares (\(shares.count)): \(shares.joined(separator: ", "))"
                    }
                } else if shares.isEmpty {
                    message = "Successfully connected and authenticated with Samba server (\(dest.host):\(dest.port)). Share '\(dest.share)' verified."
                } else {
                    message = "Connected and verified share '\(dest.share)' on \(dest.host):\(dest.port). Available shares: \(shares.joined(separator: ", "))"
                }

                await MainActor.run {
                    isTesting = false
                    testResult = (true, message)
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    testResult = (false, error.localizedDescription)
                }
            }
        }
    }

    private func buildDestination() -> SambaDestination {
        var cleanShare = share.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanShare = cleanShare.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))

        var cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanPath = cleanPath.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))

        return SambaDestination(
            id: existingDestination?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            share: cleanShare,
            path: cleanPath,
            isGuest: isGuest,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            addedDate: existingDestination?.addedDate ?? Date()
        )
    }

    private func saveDestination() {
        let dest = buildDestination()
        SambaService.shared.addDestination(dest)
        onSave?(dest)
        dismiss()
    }
}

