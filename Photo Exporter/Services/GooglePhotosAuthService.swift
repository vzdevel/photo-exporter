//
//  GooglePhotosAuthService.swift
//  Photo Exporter
//

import Foundation
import Combine
import CryptoKit
import AuthenticationServices
import UIKit

/// Manages Google OAuth 2.0 PKCE authentication flow and multiple linked accounts for Google Photos
final class GooglePhotosAuthService: NSObject, ObservableObject {
    static let shared = GooglePhotosAuthService()

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

    private let accountsStorageKey = "google_photos_accounts_v1"
    private var currentAuthSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        loadAccounts()
    }

    // MARK: - Persistence

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

    /// Launch Google OAuth sign-in flow via ASWebAuthenticationSession requesting photoslibrary.appendonly scope
    @discardableResult
    func signIn(defaultName: String = "Google Photos") async throws -> GoogleAccount {
        guard GoogleOAuthConfig.isConfigured else {
            throw NSError(
                domain: "GooglePhotosAuth",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Missing GoogleService-Info.plist configuration. Copy GoogleService-Info.plist.example to Photo Exporter/GoogleService-Info.plist and set your iOS OAuth CLIENT_ID."]
            )
        }

        await MainActor.run {
            self.isAuthenticating = true
        }
        defer {
            Task { @MainActor in
                self.isAuthenticating = false
            }
        }

        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/photoslibrary.appendonly"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent")
        ]

        guard let authURL = components.url else {
            throw NSError(domain: "GooglePhotosAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid authorization URL"])
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
                    continuation.resume(throwing: NSError(domain: "GooglePhotosAuth", code: -2, userInfo: [NSLocalizedDescriptionKey: "No callback URL received from sign in"]))
                    return
                }
                continuation.resume(returning: callbackURL)
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.currentAuthSession = session

            DispatchQueue.main.async {
                session.start()
            }
        }

        // Extract authorization code from callback
        guard let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
              let code = queryItems.first(where: { $0.name == "code" })?.value else {
            throw NSError(domain: "GooglePhotosAuth", code: -3, userInfo: [NSLocalizedDescriptionKey: "Authorization code not returned"])
        }

        // Exchange code for tokens
        let (accessToken, refreshToken, expiry) = try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier)

        // Save new account
        let newAccount = GoogleAccount(
            id: UUID().uuidString,
            name: defaultName,
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenExpiry: expiry,
            addedDate: Date()
        )

        await MainActor.run {
            self.accounts.append(newAccount)
            self.activeAccountID = newAccount.id
            self.saveAccounts()
        }

        return newAccount
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

        let bodyString = parameters
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "GooglePhotosAuth", code: -4, userInfo: [NSLocalizedDescriptionKey: "Token exchange failed: \(errorMsg)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw NSError(domain: "GooglePhotosAuth", code: -5, userInfo: [NSLocalizedDescriptionKey: "Malformed token response"])
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
            throw NSError(domain: "GooglePhotosAuth", code: -6, userInfo: [NSLocalizedDescriptionKey: "No linked Google Photos account found"])
        }

        // Return current access token if not expired (with 60-second safety window)
        if !forceRefresh && account.tokenExpiry.timeIntervalSinceNow > 60 && !account.accessToken.isEmpty {
            return account.accessToken
        }

        // Refresh token
        guard !account.refreshToken.isEmpty else {
            throw NSError(domain: "GooglePhotosAuth", code: -7, userInfo: [NSLocalizedDescriptionKey: "No refresh token available for \(account.name). Please sign in again."])
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let parameters: [String: String] = [
            "client_id": clientID,
            "refresh_token": account.refreshToken,
            "grant_type": "refresh_token"
        ]

        let bodyString = parameters
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String else {
            throw NSError(domain: "GooglePhotosAuth", code: -8, userInfo: [NSLocalizedDescriptionKey: "Session expired for \(account.name). Please sign in again."])
        }

        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
        let expiryDate = Date().addingTimeInterval(expiresIn)

        await MainActor.run {
            if let idx = self.accounts.firstIndex(where: { $0.id == account.id }) {
                var updated = self.accounts[idx]
                updated.accessToken = newAccessToken
                updated.tokenExpiry = expiryDate
                self.accounts[idx] = updated
                self.saveAccounts()
            }
        }

        return newAccessToken
    }

    /// Unlink / remove a specific Google Photos account
    func unlinkAccount(id: String) {
        if let acc = accounts.first(where: { $0.id == id }) {
            if let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke?token=\(acc.accessToken)") {
                var request = URLRequest(url: revokeURL)
                request.httpMethod = "POST"
                URLSession.shared.dataTask(with: request).resume()
            }
        }

        accounts.removeAll { $0.id == id }
        if activeAccountID == id {
            activeAccountID = accounts.first?.id
        }
        saveAccounts()
    }

    /// Unlink all Google Photos accounts
    func signOut() {
        for acc in accounts {
            unlinkAccount(id: acc.id)
        }
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension GooglePhotosAuthService: ASWebAuthenticationPresentationContextProviding {
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
