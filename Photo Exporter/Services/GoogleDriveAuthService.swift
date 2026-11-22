//
//  GoogleDriveAuthService.swift
//  Photo Exporter
//

import Foundation
import Combine
import CryptoKit
import AuthenticationServices
import UIKit

/// Manages Google OAuth 2.0 PKCE authentication flow and multiple linked accounts for Google Drive
final class GoogleDriveAuthService: NSObject, ObservableObject {
    static let shared = GoogleDriveAuthService()

    @Published var accounts: [GoogleAccount] = []
    @Published var activeAccountID: String? = nil
    @Published var isAuthenticating: Bool = false

    var isAuthenticated: Bool {
        !accounts.isEmpty
    }

    var activeAccount: GoogleAccount? {
        if let id = activeAccountID, let acc = accounts.first(where: { $0.id == id }) {
            return acc
        }
        return accounts.first
    }

    // OAuth 2.0 configuration loaded from GoogleService-Info.plist
    var clientID: String { GoogleOAuthConfig.clientID }
    var redirectURI: String { GoogleOAuthConfig.redirectURI }
    var callbackURLScheme: String { GoogleOAuthConfig.callbackURLScheme }

    private let accountsStorageKey = "google_drive_accounts_v2"
    private var currentAuthSession: ASWebAuthenticationSession?
    private var refreshTasks: [String: Task<String, Error>] = [:]
    private var foregroundObserver: NSObjectProtocol?

    private static let apiSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15.0
        config.timeoutIntervalForResource = 60.0
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    override init() {
        super.init()
        loadAccounts()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { _ in
            Self.apiSession.flush {}
        }
    }

    /// Executes a short-lived Google Drive / OAuth HTTP request on a connectivity-aware session,
    /// flushing dead keep-alive sockets and retrying on transient post-background network errors.
    static func performResilientDataRequest(_ request: URLRequest, maxAttempts: Int = 3) async throws -> (Data, URLResponse) {
        let retryableCodes: Set<URLError.Code> = [
            .timedOut,
            .networkConnectionLost,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
            .notConnectedToInternet
        ]

        var lastError: Error?
        for attempt in 0..<max(1, maxAttempts) {
            try Task.checkCancellation()
            do {
                return try await apiSession.data(for: request)
            } catch {
                if error is CancellationError {
                    throw error
                }
                if let urlError = error as? URLError {
                    if urlError.code == .cancelled {
                        throw error
                    }
                    guard retryableCodes.contains(urlError.code), attempt + 1 < maxAttempts else {
                        throw error
                    }
                    lastError = error
                    await withCheckedContinuation { continuation in
                        apiSession.flush {
                            continuation.resume()
                        }
                    }
                    let delayNs = UInt64(250_000_000 * (attempt + 1))
                    try await Task.sleep(nanoseconds: delayNs)
                    continue
                }
                throw error
            }
        }
        throw lastError ?? URLError(.timedOut)
    }

    // MARK: - Persistence & Migration

    private func loadAccounts() {
        if let data = UserDefaults.standard.data(forKey: accountsStorageKey),
           let list = try? JSONDecoder().decode([GoogleAccount].self, from: data) {
            self.accounts = list
            self.activeAccountID = list.first?.id
        }
    }

    func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsStorageKey)
        }
    }

    func updateAccountName(id: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = accounts.firstIndex(where: { $0.id == id }) {
            accounts[idx].name = trimmed
            saveAccounts()
        }
    }

    func updateAccount(
        id: String,
        name: String,
        email: String?,
        folderId: String,
        folderName: String,
        folderPath: String,
        folderBreadcrumbs: [GoogleDriveFolderBreadcrumb] = []
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = accounts.firstIndex(where: { $0.id == id }) {
            accounts[idx].name = trimmed
            if let email = email, !email.isEmpty {
                accounts[idx].email = email
            }
            accounts[idx].folderId = folderId
            accounts[idx].folderName = folderName
            accounts[idx].folderPath = folderPath
            accounts[idx].folderBreadcrumbs = folderBreadcrumbs
            saveAccounts()
        }
    }

    /// Fetch email and display name for user via Google Drive v3 About endpoint
    func fetchUserInfo(accessToken: String) async -> (email: String?, displayName: String?) {
        guard let aboutURL = URL(string: "https://www.googleapis.com/drive/v3/about?fields=user(displayName,emailAddress)") else {
            return (nil, nil)
        }
        var request = URLRequest(url: aboutURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let (data, response) = try? await Self.performResilientDataRequest(request),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let user = json["user"] as? [String: Any] {
            let email = user["emailAddress"] as? String
            let name = user["displayName"] as? String
            if let email = email, !email.isEmpty {
                return (email, name)
            }
        }

        return (nil, nil)
    }

    /// Fetch and persist email for an account if not already saved
    func fetchAccountEmail(for accountID: String) async -> String? {
        guard let token = try? await getValidAccessToken(for: accountID) else { return nil }
        let (email, _) = await fetchUserInfo(accessToken: token)
        if let email = email, !email.isEmpty {
            await MainActor.run {
                if let idx = self.accounts.firstIndex(where: { $0.id == accountID }) {
                    self.accounts[idx].email = email
                    self.saveAccounts()
                }
            }
            return email
        }
        return nil
    }

    // MARK: - PKCE Utilities

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return "" }
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - OAuth Flow

    /// Launch Google OAuth sign-in flow via ASWebAuthenticationSession for Google Drive
    @discardableResult
    func signIn(defaultName: String = "Google Drive") async throws -> GoogleAccount {
        let authResult = try await performOAuthSignIn()

        let newAccount = GoogleAccount(
            id: UUID().uuidString,
            name: defaultName,
            email: authResult.email,
            folderId: "root",
            folderName: "My Drive",
            folderPath: "My Drive",
            accessToken: authResult.accessToken,
            refreshToken: authResult.refreshToken,
            tokenExpiry: authResult.expiry,
            addedDate: Date()
        )

        self.accounts.append(newAccount)
        self.activeAccountID = newAccount.id
        self.saveAccounts()

        return newAccount
    }

    /// Re-authenticate an existing Google Drive account in-place, preserving its name and folder configuration.
    @discardableResult
    func reauthenticate(accountID: String) async throws -> GoogleAccount {
        guard let existingIndex = accounts.firstIndex(where: { $0.id == accountID }) else {
            throw NSError(domain: "GoogleDriveAuth", code: -6, userInfo: [NSLocalizedDescriptionKey: "No linked Google Drive account found"])
        }

        let authResult = try await performOAuthSignIn(loginHint: accounts[existingIndex].email)

        var updated = accounts[existingIndex]
        updated.accessToken = authResult.accessToken
        if !authResult.refreshToken.isEmpty {
            updated.refreshToken = authResult.refreshToken
        }
        updated.tokenExpiry = authResult.expiry
        if let newEmail = authResult.email, !newEmail.isEmpty {
            updated.email = newEmail
        }
        accounts[existingIndex] = updated
        saveAccounts()

        return updated
    }

    private func performOAuthSignIn(loginHint: String? = nil) async throws -> (accessToken: String, refreshToken: String, expiry: Date, email: String?) {
        guard GoogleOAuthConfig.isConfigured else {
            throw NSError(
                domain: "GoogleDriveAuth",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Missing GoogleService-Info.plist configuration. Copy GoogleService-Info.plist.example to Photo Exporter/GoogleService-Info.plist and set your iOS OAuth CLIENT_ID."]
            )
        }

        self.isAuthenticating = true
        defer { self.isAuthenticating = false }

        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        var queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            // Prompt select_account so the user can choose or link a different Google account
            URLQueryItem(name: "prompt", value: "select_account consent")
        ]
        if let loginHint = loginHint, !loginHint.isEmpty {
            queryItems.append(URLQueryItem(name: "login_hint", value: loginHint))
        }
        components.queryItems = queryItems

        guard let authURL = components.url else {
            throw NSError(domain: "GoogleDriveAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid authorization URL"])
        }

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackURLScheme
            ) { [weak self] callbackURL, error in
                self?.currentAuthSession = nil
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL = callbackURL else {
                    continuation.resume(throwing: NSError(domain: "GoogleDriveAuth", code: -2, userInfo: [NSLocalizedDescriptionKey: "No callback URL received from sign in"]))
                    return
                }
                continuation.resume(returning: callbackURL)
            }

            session.presentationContextProvider = self
            // Ephemeral session allows user to log into multiple separate accounts
            session.prefersEphemeralWebBrowserSession = true
            self.currentAuthSession = session

            DispatchQueue.main.async {
                session.start()
            }
        }

        // Extract authorization code from callback
        guard let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
              let code = queryItems.first(where: { $0.name == "code" })?.value else {
            throw NSError(domain: "GoogleDriveAuth", code: -3, userInfo: [NSLocalizedDescriptionKey: "Authorization code not returned"])
        }

        // Exchange code for tokens
        let (accessToken, refreshToken, expiry) = try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier)

        // Fetch user info (email address)
        let (userEmail, _) = await fetchUserInfo(accessToken: accessToken)

        return (accessToken, refreshToken, expiry, userEmail)
    }

    private func formURLEncodedBody(_ parameters: [String: String]) -> Data? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let bodyString = parameters
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
        return bodyString.data(using: .utf8)
    }

    private func exchangeCodeForTokens(code: String, codeVerifier: String) async throws -> (accessToken: String, refreshToken: String, expiry: Date) {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let parameters: [String: String] = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier
        ]
        request.httpBody = formURLEncodedBody(parameters)

        let (data, response) = try await Self.performResilientDataRequest(request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "GoogleDriveAuth", code: -4, userInfo: [NSLocalizedDescriptionKey: "Token exchange failed: \(errorMsg)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw NSError(domain: "GoogleDriveAuth", code: -5, userInfo: [NSLocalizedDescriptionKey: "Malformed token response"])
        }

        if let grantedScope = json["scope"] as? String {
            let scopes = Set(grantedScope.split(separator: " ").map(String.init))
            if !scopes.contains("https://www.googleapis.com/auth/drive") {
                throw NSError(
                    domain: "GoogleDriveAuth",
                    code: -10,
                    userInfo: [NSLocalizedDescriptionKey: "Google Drive read/write permission was not granted. Please sign in again and allow Google Drive access."]
                )
            }
        }

        let refreshToken = (json["refresh_token"] as? String) ?? ""
        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
        let expiryDate = Date().addingTimeInterval(expiresIn)

        return (accessToken, refreshToken, expiryDate)
    }

    /// Retrieve a valid access token for the given account ID or active account, refreshing if expired or forced
    func getValidAccessToken(for accountID: String? = nil, forceRefresh: Bool = false) async throws -> String {
        let targetID = accountID ?? activeAccountID ?? accounts.first?.id
        guard let account = accounts.first(where: { $0.id == targetID }) else {
            throw NSError(domain: "GoogleDriveAuth", code: -6, userInfo: [NSLocalizedDescriptionKey: "No linked Google Drive account found"])
        }

        // Return current access token if not expired and not forced
        if !forceRefresh && account.tokenExpiry.timeIntervalSinceNow > 60 && !account.accessToken.isEmpty {
            return account.accessToken
        }

        // Refresh token (coalesce concurrent refresh requests for the same account)
        guard !account.refreshToken.isEmpty else {
            throw NSError(domain: "GoogleDriveAuth", code: -7, userInfo: [NSLocalizedDescriptionKey: "No refresh token available for \(account.name). Please sign in again."])
        }

        if let existingTask = refreshTasks[account.id] {
            return try await existingTask.value
        }

        let task = Task<String, Error> {
            defer { self.refreshTasks.removeValue(forKey: account.id) }

            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let parameters: [String: String] = [
                "client_id": self.clientID,
                "refresh_token": account.refreshToken,
                "grant_type": "refresh_token"
            ]
            request.httpBody = self.formURLEncodedBody(parameters)

            let (data, response) = try await Self.performResilientDataRequest(request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard statusCode == 200, let newAccessToken = json?["access_token"] as? String else {
                let oauthError = json?["error"] as? String ?? ""
                let oauthDesc = json?["error_description"] as? String ?? ""
                print("GoogleDriveAuth refresh failed (HTTP \(statusCode)): \(oauthError) \(oauthDesc)")

                if statusCode >= 500 || statusCode == 429 {
                    throw NSError(domain: "GoogleDriveAuth", code: -9, userInfo: [NSLocalizedDescriptionKey: "Temporary Google auth error (HTTP \(statusCode)). Please try again."])
                }

                let detail = oauthError == "invalid_grant"
                    ? "Session expired for \(account.name) (if your Google Cloud OAuth app is in Testing mode, refresh tokens expire every 7 days). Please sign in again."
                    : "Session expired for \(account.name). Please sign in again."
                throw NSError(domain: "GoogleDriveAuth", code: -8, userInfo: [NSLocalizedDescriptionKey: detail])
            }

            let expiresIn = json?["expires_in"] as? TimeInterval ?? 3600
            let expiryDate = Date().addingTimeInterval(expiresIn)
            let rotatedRefreshToken = json?["refresh_token"] as? String

            if let idx = self.accounts.firstIndex(where: { $0.id == account.id }) {
                var updated = self.accounts[idx]
                updated.accessToken = newAccessToken
                updated.tokenExpiry = expiryDate
                if let rotated = rotatedRefreshToken, !rotated.isEmpty {
                    updated.refreshToken = rotated
                }
                self.accounts[idx] = updated
                self.saveAccounts()
            }

            return newAccessToken
        }

        refreshTasks[account.id] = task
        return try await task.value
    }

    private struct LastBrowsedFolder: Codable {
        let folderId: String
        let folderName: String
        let folderPath: String
        let folderBreadcrumbs: [GoogleDriveFolderBreadcrumb]
    }

    private static func lastBrowsedFolderStorageKey(for accountID: String) -> String {
        "last_browsed_gdrive_folder_\(accountID)"
    }

    /// Returns a copy of `account` positioned at the user's last-picked media-source folder if one was recorded.
    func lastBrowsedAccount(for account: GoogleAccount) -> GoogleAccount {
        guard let data = UserDefaults.standard.data(forKey: Self.lastBrowsedFolderStorageKey(for: account.id)),
              let saved = try? JSONDecoder().decode(LastBrowsedFolder.self, from: data) else {
            return account
        }
        var copy = account
        copy.folderId = saved.folderId
        copy.folderName = saved.folderName
        copy.folderPath = saved.folderPath
        copy.folderBreadcrumbs = saved.folderBreadcrumbs
        return copy
    }

    /// Remembers the folder picked while browsing this Google Drive account as a media source.
    func saveLastBrowsedFolder(for account: GoogleAccount) {
        let payload = LastBrowsedFolder(
            folderId: account.targetFolderId,
            folderName: account.targetFolderName,
            folderPath: account.folderPath.isEmpty ? account.targetFolderName : account.folderPath,
            folderBreadcrumbs: account.folderBreadcrumbs
        )
        if let encoded = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(encoded, forKey: Self.lastBrowsedFolderStorageKey(for: account.id))
        }
    }

    /// Unlink / remove a specific Google account
    func unlinkAccount(id: String) {
        if let acc = accounts.first(where: { $0.id == id }) {
            if let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke?token=\(acc.accessToken)") {
                var request = URLRequest(url: revokeURL)
                request.httpMethod = "POST"
                URLSession.shared.dataTask(with: request).resume()
            }
        }

        accounts.removeAll { $0.id == id }
        UserDefaults.standard.removeObject(forKey: Self.lastBrowsedFolderStorageKey(for: id))
        if activeAccountID == id {
            activeAccountID = accounts.first?.id
        }
        saveAccounts()
    }

    /// Unlink all accounts
    func signOut() {
        for acc in accounts {
            unlinkAccount(id: acc.id)
        }
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension GoogleDriveAuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
                return window
            }
        }
        return UIWindow()
    }
}

