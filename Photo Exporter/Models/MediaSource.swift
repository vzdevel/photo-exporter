//
//  MediaSource.swift
//  Photo Exporter
//

import Foundation
import SwiftUI

/// Represents a clickable breadcrumb segment in the folder path bar.
struct FolderPathSegment: Identifiable, Hashable {
    let id: String
    let name: String
    let targetSource: MediaSource
}

/// Represents a subfolder entry shown inside the folder media list view.
struct FolderListEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let modificationDate: Date?
    let targetSource: MediaSource
    var isDeletable: Bool = true
}

/// Scoped access wrapper ensuring security-scoped access is started on the root bookmarked URL
/// even when browsing a nested subdirectory inside that local folder.
struct LocalFolderAccess {
    let folderURL: URL
    private let scopeURL: URL?
    private let didStartScope: Bool

    init(folderURL: URL, scopeURL: URL?, didStartScope: Bool) {
        self.folderURL = folderURL
        self.scopeURL = scopeURL
        self.didStartScope = didStartScope
    }

    func stop() {
        if didStartScope, let scopeURL {
            scopeURL.stopAccessingSecurityScopedResource()
        }
    }
}

/// Represents the active media source displayed in the main list view
enum MediaSource: Identifiable, Hashable, Codable {
    case photoLibrary
    case localFolder(bookmarkData: Data?, path: String, displayName: String)
    case googleDrive(account: GoogleAccount)
    case samba(destination: SambaDestination)

    var id: String { sourceKey }

    var isFolder: Bool {
        if case .photoLibrary = self { return false }
        return true
    }

    var isRemote: Bool {
        switch self {
        case .googleDrive, .samba:
            return true
        case .photoLibrary, .localFolder:
            return false
        }
    }

    /// Stable key used to isolate cached metadata & list items per source
    var sourceKey: String {
        switch self {
        case .photoLibrary:
            return "photo_library"
        case .localFolder(_, let path, _):
            return "local_\(path)"
        case .googleDrive(let account):
            return "gdrive_\(account.id)_\(account.folderId)"
        case .samba(let destination):
            let cleanShare = destination.share.trimmingCharacters(in: CharacterSet(charactersIn: " /\\"))
            let cleanPath = destination.path.trimmingCharacters(in: CharacterSet(charactersIn: " /\\"))
            return "samba_\(destination.id)_\(cleanShare)_\(cleanPath)"
        }
    }

    static func friendlyLocalFolderName(for component: String, fallback: String = "Local Folder") -> String {
        if component == "com~apple~CloudDocs" {
            return "iCloud"
        }
        return component.isEmpty ? fallback : component
    }

    var navigationTitle: String {
        switch self {
        case .photoLibrary:
            return "Photo Library"
        case .localFolder(_, _, let displayName):
            return Self.friendlyLocalFolderName(for: displayName)
        case .googleDrive(let account):
            return account.name
        case .samba(let destination):
            return destination.name
        }
    }

    var subtitle: String {
        switch self {
        case .photoLibrary:
            return "iPhone Photos & Videos"
        case .localFolder(_, let path, _):
            return path
        case .googleDrive(let account):
            return account.gdrivePathDisplayString
        case .samba(let destination):
            return destination.sharePathDisplayString
        }
    }

    var iconName: String {
        switch self {
        case .photoLibrary:
            return "photo.on.rectangle.angled"
        case .localFolder:
            return "folder.fill"
        case .googleDrive:
            return "GoogleDriveIcon"
        case .samba:
            return "server.rack"
        }
    }

    var isAssetIcon: Bool {
        if case .googleDrive = self { return true }
        return false
    }

    var iconColor: Color {
        switch self {
        case .photoLibrary:
            return .blue
        case .localFolder:
            return .blue
        case .googleDrive:
            return .green
        case .samba:
            return .indigo
        }
    }

    /// Resolves the target local folder URL (preserving nested subpath relative to the security-scoped root bookmark).
    func resolveLocalFolderURL() -> URL? {
        guard case .localFolder(let bookmarkData, let path, _) = self else { return nil }
        return resolveLocalURLPair(bookmarkData: bookmarkData, path: path).targetURL
    }

    /// Starts security-scoped access on the root bookmarked folder (if any) and returns the target folder URL.
    func beginLocalFolderAccess() -> LocalFolderAccess? {
        guard case .localFolder(let bookmarkData, let path, _) = self else { return nil }
        let (targetURL, rootScopeURL) = resolveLocalURLPair(bookmarkData: bookmarkData, path: path)
        let didStart = rootScopeURL?.startAccessingSecurityScopedResource() ?? false
        return LocalFolderAccess(folderURL: targetURL, scopeURL: rootScopeURL, didStartScope: didStart)
    }

    private func resolveLocalURLPair(bookmarkData: Data?, path: String) -> (targetURL: URL, scopeURL: URL?) {
        let targetPathURL = URL(fileURLWithPath: path)
        if let bookmarkData {
            var isStale = false
            if let rootURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                let rootStd = rootURL.standardizedFileURL.path
                let targetStd = targetPathURL.standardizedFileURL.path
                if targetStd == rootStd {
                    return (rootURL, rootURL)
                }
                if targetStd.hasPrefix(rootStd + "/") {
                    let relative = String(targetStd.dropFirst(rootStd.count + 1))
                    return (rootURL.appendingPathComponent(relative, isDirectory: true), rootURL)
                }
                return (targetPathURL, rootURL)
            }
        }
        return (targetPathURL, nil)
    }

    /// Full navigable path segments for the current folder source.
    var folderPathSegments: [FolderPathSegment] {
        switch self {
        case .photoLibrary:
            return []

        case .localFolder(let bookmarkData, let path, let displayName):
            let (targetURL, rootURL) = resolveLocalURLPair(bookmarkData: bookmarkData, path: path)
            guard let rootURL else {
                let rawName = displayName.isEmpty ? targetURL.lastPathComponent : displayName
                let name = Self.friendlyLocalFolderName(for: rawName)
                return [FolderPathSegment(id: targetURL.standardizedFileURL.path, name: name, targetSource: self)]
            }
            let rootStd = rootURL.standardizedFileURL
            let targetStd = targetURL.standardizedFileURL
            let rootName = Self.friendlyLocalFolderName(for: rootStd.lastPathComponent.isEmpty ? displayName : rootStd.lastPathComponent)
            var segments = [
                FolderPathSegment(
                    id: rootStd.path,
                    name: rootName,
                    targetSource: .localFolder(bookmarkData: bookmarkData, path: rootURL.path, displayName: rootName)
                )
            ]
            if targetStd.path.hasPrefix(rootStd.path + "/") {
                let relParts = targetStd.path
                    .dropFirst(rootStd.path.count + 1)
                    .split(separator: "/")
                    .map(String.init)
                    .filter { !$0.isEmpty }
                var runningURL = rootURL
                for part in relParts {
                    runningURL = runningURL.appendingPathComponent(part, isDirectory: true)
                    let partName = Self.friendlyLocalFolderName(for: part)
                    let segSource = MediaSource.localFolder(bookmarkData: bookmarkData, path: runningURL.path, displayName: partName)
                    segments.append(FolderPathSegment(id: runningURL.standardizedFileURL.path, name: partName, targetSource: segSource))
                }
            }
            return segments

        case .googleDrive(let account):
            let crumbs: [GoogleDriveFolderBreadcrumb]
            if !account.folderBreadcrumbs.isEmpty {
                crumbs = account.folderBreadcrumbs
            } else if account.targetFolderId == "root" {
                crumbs = [GoogleDriveFolderBreadcrumb(id: "root", name: "My Drive")]
            } else {
                let parts = account.folderPath
                    .split(separator: "/")
                    .map(String.init)
                    .filter { !$0.isEmpty }
                if parts.count >= 2 && parts.first == "My Drive" {
                    crumbs = [GoogleDriveFolderBreadcrumb(id: "root", name: "My Drive")] + parts.dropFirst().dropLast().enumerated().map { idx, name in
                        GoogleDriveFolderBreadcrumb(id: "placeholder_\(idx)_\(name)", name: name)
                    } + [GoogleDriveFolderBreadcrumb(id: account.targetFolderId, name: account.targetFolderName)]
                } else {
                    crumbs = [GoogleDriveFolderBreadcrumb(id: account.targetFolderId, name: account.targetFolderName)]
                }
            }

            return crumbs.indices.map { i in
                let prefixCrumbs = Array(crumbs[0...i])
                let targetCrumb = crumbs[i]
                var copy = account
                copy.folderId = targetCrumb.id
                copy.folderName = targetCrumb.name
                copy.folderPath = prefixCrumbs.map(\.name).joined(separator: "/")
                copy.folderBreadcrumbs = prefixCrumbs
                return FolderPathSegment(
                    id: targetCrumb.id,
                    name: targetCrumb.name,
                    targetSource: .googleDrive(account: copy)
                )
            }

        case .samba(let destination):
            let cleanHost = destination.host.trimmingCharacters(in: .whitespacesAndNewlines)
            let rootLabel = cleanHost.isEmpty ? destination.displayName : cleanHost
            var hostRootDest = destination
            hostRootDest.share = ""
            hostRootDest.path = ""
            var segments = [
                FolderPathSegment(
                    id: "smb:\(destination.id):_host_",
                    name: rootLabel,
                    targetSource: .samba(destination: hostRootDest)
                )
            ]

            let cleanShare = destination.share.trimmingCharacters(in: CharacterSet(charactersIn: " /\\"))
            if !cleanShare.isEmpty {
                var shareRootDest = destination
                shareRootDest.share = cleanShare
                shareRootDest.path = ""
                segments.append(
                    FolderPathSegment(
                        id: "smb:\(destination.id):\(cleanShare):",
                        name: cleanShare,
                        targetSource: .samba(destination: shareRootDest)
                    )
                )

                let parts = destination.path
                    .replacingOccurrences(of: "\\", with: "/")
                    .split(separator: "/")
                    .map(String.init)
                    .filter { !$0.isEmpty }

                var running = ""
                for part in parts {
                    running = running.isEmpty ? part : "\(running)/\(part)"
                    var subDest = destination
                    subDest.share = cleanShare
                    subDest.path = running
                    segments.append(
                        FolderPathSegment(
                            id: "smb:\(destination.id):\(cleanShare):\(running)",
                            name: part,
                            targetSource: .samba(destination: subDest)
                        )
                    )
                }
            }
            return segments
        }
    }

    /// Creates a child folder `MediaSource` inside this folder source.
    func childFolderSource(name: String, folderId: String? = nil) -> MediaSource? {
        switch self {
        case .photoLibrary:
            return nil
        case .localFolder(let bookmarkData, let path, _):
            let childURL = resolveLocalURLPair(bookmarkData: bookmarkData, path: path).targetURL
                .appendingPathComponent(name, isDirectory: true)
            return .localFolder(bookmarkData: bookmarkData, path: childURL.path, displayName: Self.friendlyLocalFolderName(for: name))
        case .googleDrive(let account):
            guard let childId = folderId else { return nil }
            var copy = account
            let baseCrumbs: [GoogleDriveFolderBreadcrumb] = account.folderBreadcrumbs.isEmpty
                ? (account.targetFolderId == "root"
                   ? [GoogleDriveFolderBreadcrumb(id: "root", name: "My Drive")]
                   : [GoogleDriveFolderBreadcrumb(id: account.targetFolderId, name: account.targetFolderName)])
                : account.folderBreadcrumbs
            let nextCrumbs = baseCrumbs + [GoogleDriveFolderBreadcrumb(id: childId, name: name)]
            copy.folderId = childId
            copy.folderName = name
            copy.folderBreadcrumbs = nextCrumbs
            copy.folderPath = nextCrumbs.map(\.name).joined(separator: "/")
            return .googleDrive(account: copy)
        case .samba(let destination):
            var copy = destination
            let cleanShare = destination.share.trimmingCharacters(in: CharacterSet(charactersIn: " /\\"))
            if cleanShare.isEmpty {
                copy.share = name
                copy.path = ""
            } else {
                let cleanCurrent = destination.path.trimmingCharacters(in: CharacterSet(charactersIn: " /\\"))
                copy.path = cleanCurrent.isEmpty ? name : "\(cleanCurrent)/\(name)"
            }
            return .samba(destination: copy)
        }
    }

    static func == (lhs: MediaSource, rhs: MediaSource) -> Bool {
        lhs.sourceKey == rhs.sourceKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(sourceKey)
    }
}

