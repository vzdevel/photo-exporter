//
//  SMB2Client.swift
//  Photo Exporter
//
//  Created by Antigravity on 2026-11-01.
//

import Foundation
import Network
import CommonCrypto

typealias SMB2AuthenticationTester = SMB2Client

/// Performs SMB2 protocol negotiation, NTLMv2 session authentication, share verification, and file operations
enum SMB2Client {

    // MARK: - Public API

    /// Connects to the Samba server, negotiates SMB2, authenticates credentials (or guest access), and tests share access
    static func testAuthentication(destination: SambaDestination, timeoutSeconds: Double = 6.0) async throws {
        let session = try await openSession(destination: destination, timeoutSeconds: timeoutSeconds)
        await session.disconnect()
    }

    /// Enumerates visible disk shares on the Samba server via DCE/RPC SRVSVC over IPC$
    static func listShares(destination: SambaDestination, timeoutSeconds: Double = 8.0) async throws -> [String] {
        var ipcDestination = destination
        ipcDestination.share = "IPC$"
        ipcDestination.path = ""
        let session = try await openSession(destination: ipcDestination, timeoutSeconds: timeoutSeconds)
        do {
            let shares = try await session.listShares()
            await session.disconnect()
            return shares
        } catch {
            await session.disconnect()
            throw error
        }
    }

    /// Connects to the Samba server, negotiates SMB2, authenticates credentials, and attaches to the target share
    static func openSession(destination: SambaDestination, timeoutSeconds: Double = 8.0) async throws -> SMB2ClientSession {
        let hostStr = destination.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostStr.isEmpty else {
            throw makeError("Server host or IP cannot be empty.")
        }

        let portNum = UInt16(destination.port)
        guard let nwPort = NWEndpoint.Port(rawValue: portNum) else {
            throw makeError("Invalid port: \(destination.port)")
        }

        if !destination.isGuest && destination.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw makeError("Username is required when guest access is disabled.")
        }

        let host = NWEndpoint.Host(hostStr)
        let parameters = NWParameters.tcp
        let connection = NWConnection(host: host, port: nwPort, using: parameters)

        // 1. Establish TCP connection
        try await waitForReady(connection: connection, host: hostStr, port: portNum, timeout: timeoutSeconds)

        var messageId: UInt64 = 0

        // 2. Step 1: SMB2 NEGOTIATE
        let negMsgId = messageId
        let negRequest = buildNegotiatePacket(messageId: negMsgId)
        messageId += 1
        try await sendFramedPacket(connection: connection, payload: negRequest)

        let negResponse = try await readCommandResponse(connection: connection, expectedCommand: 0, messageId: negMsgId)
        guard let negParsed = parseSMB2Header(data: negResponse) else {
            connection.cancel()
            throw makeError("Server at \(hostStr):\(portNum) is not a valid SMB server.")
        }

        if negParsed.status != 0 {
            connection.cancel()
            throw makeError("SMB negotiation failed with status: \(describeStatus(negParsed.status))")
        }

        let isSPNEGO = checkIfSPNEGO(negResponse)

        // 3. Step 2: SMB2 SESSION_SETUP (Phase 1: NTLMSSP Negotiate)
        let phase1MsgId = messageId
        let ntlmType1 = buildNTLMSSPNegotiate()
        let phase1Token = isSPNEGO ? wrapSPNEGONegTokenInit(ntlmToken: ntlmType1) : ntlmType1
        let phase1Request = buildSessionSetupPacket(
            messageId: phase1MsgId,
            sessionId: 0,
            securityToken: phase1Token
        )
        messageId += 1
        try await sendFramedPacket(connection: connection, payload: phase1Request)

        let phase1Response = try await readCommandResponse(connection: connection, expectedCommand: 1, messageId: phase1MsgId)
        guard let phase1Parsed = parseSMB2Header(data: phase1Response) else {
            connection.cancel()
            throw makeError("Failed to parse Session Setup response from \(hostStr).")
        }

        if phase1Parsed.status != 0xC0000016 && phase1Parsed.status != 0x00000000 {
            connection.cancel()
            throw makeError("Session setup initialization failed with status: \(describeStatus(phase1Parsed.status))")
        }

        let assignedSessionId = phase1Parsed.sessionId

        guard let secBuffer = extractSecurityBuffer(from: phase1Response),
              let challengeInfo = parseNTLMSSPChallenge(securityBuffer: secBuffer) else {
            connection.cancel()
            throw makeError("Failed to extract NTLM challenge from server response.")
        }

        // 4. Step 3: SMB2 SESSION_SETUP (Phase 2: NTLMSSP Authenticate)
        let phase2MsgId = messageId
        let ntlmType3 = buildNTLMSSPAuthenticate(
            destination: destination,
            serverChallenge: challengeInfo.serverChallenge,
            targetInfo: challengeInfo.targetInfo
        )

        let phase2Token = isSPNEGO ? wrapSPNEGONegTokenResp(ntlmToken: ntlmType3) : ntlmType3
        let phase2Request = buildSessionSetupPacket(
            messageId: phase2MsgId,
            sessionId: assignedSessionId,
            securityToken: phase2Token
        )
        messageId += 1
        try await sendFramedPacket(connection: connection, payload: phase2Request)

        let phase2Response = try await readCommandResponse(connection: connection, expectedCommand: 1, messageId: phase2MsgId)
        guard let phase2Parsed = parseSMB2Header(data: phase2Response) else {
            connection.cancel()
            throw makeError("Failed to parse authentication response from \(hostStr).")
        }

        // Check authentication outcome
        switch phase2Parsed.status {
        case 0x00000000:
            if phase2Response.count >= 68 {
                let sessionFlags = UInt16(phase2Response[66]) | (UInt16(phase2Response[67]) << 8)
                let isGuestSession = (sessionFlags & 0x0001) != 0
                if !destination.isGuest && isGuestSession {
                    connection.cancel()
                    throw makeError("Authentication failed: The server rejected your credentials and logged in as Guest. Please verify your username and password.")
                }
            }

        case 0xC000006D: // STATUS_LOGON_FAILURE
            connection.cancel()
            if destination.isGuest {
                throw makeError("Authentication failed: This server requires authentication and does not allow guest access. Please enter a valid username and password.")
            } else {
                throw makeError("Authentication failed: Incorrect username or password.")
            }

        case 0xC0000022: // STATUS_ACCESS_DENIED
            connection.cancel()
            if destination.isGuest {
                throw makeError("Authentication failed: Guest access was denied by the server. Please enter a valid username and password.")
            } else {
                throw makeError("Authentication failed: Access denied for user '\(destination.username)'.")
            }

        case 0xC000006E: // STATUS_ACCOUNT_RESTRICTION
            connection.cancel()
            throw makeError("Authentication failed: Account has logon restrictions preventing access.")

        case 0xC0000071: // STATUS_PASSWORD_EXPIRED
            connection.cancel()
            throw makeError("Authentication failed: The password for this account has expired.")

        case 0xC0000072: // STATUS_ACCOUNT_DISABLED
            connection.cancel()
            throw makeError("Authentication failed: This account is currently disabled.")

        default:
            connection.cancel()
            throw makeError("Authentication failed: \(describeStatus(phase2Parsed.status))")
        }

        // 5. Step 4: SMB2 TREE_CONNECT (verify share existence and permissions)
        let cleanShare = destination.share.trimmingCharacters(in: CharacterSet(charactersIn: " /\\"))
        var treeId: UInt32 = 0
        if !cleanShare.isEmpty {
            let treeMsgId = messageId
            let treeRequest = buildTreeConnectPacket(
                host: hostStr,
                share: cleanShare,
                sessionId: assignedSessionId,
                messageId: treeMsgId
            )
            messageId += 1
            try await sendFramedPacket(connection: connection, payload: treeRequest)

            let treeResponse = try await readCommandResponse(connection: connection, expectedCommand: 3, messageId: treeMsgId)
            guard let treeParsed = parseSMB2Header(data: treeResponse) else {
                connection.cancel()
                throw makeError("Failed to parse Tree Connect response from \(hostStr).")
            }

            switch treeParsed.status {
            case 0x00000000:
                treeId = treeParsed.treeId
            case 0xC00000CC: // STATUS_BAD_NETWORK_NAME
                connection.cancel()
                throw makeError("Authentication succeeded, but the share '\(cleanShare)' does not exist on \(hostStr).")
            case 0xC0000022: // STATUS_ACCESS_DENIED
                connection.cancel()
                throw makeError("Authentication succeeded, but access to the share '\(cleanShare)' was denied. Please verify user permissions.")
            default:
                connection.cancel()
                throw makeError("Failed to access share '\(cleanShare)': \(describeStatus(treeParsed.status))")
            }
        }

        return SMB2ClientSession(
            connection: connection,
            host: hostStr,
            sessionId: assignedSessionId,
            treeId: treeId,
            initialMessageId: messageId
        )
    }

    // MARK: - TCP Connection Helper

    private static func waitForReady(
        connection: NWConnection,
        host: String,
        port: UInt16,
        timeout: Double
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var hasResumed = false
            let queue = DispatchQueue(label: "com.photoexporter.samba.auth.test")

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                guard !hasResumed else { return }
                hasResumed = true
                connection.cancel()
                continuation.resume(throwing: makeError("Connection timed out connecting to \(host):\(port). Please verify the server address and that your device is connected to the same local Wi-Fi or VPN."))
            }
            timer.resume()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !hasResumed else { return }
                    hasResumed = true
                    timer.cancel()
                    continuation.resume()

                case .failed(let error):
                    guard !hasResumed else { return }
                    hasResumed = true
                    timer.cancel()
                    connection.cancel()
                    continuation.resume(throwing: makeError("Cannot reach server at \(host):\(port): \(error.localizedDescription)"))

                case .cancelled:
                    if !hasResumed {
                        hasResumed = true
                        timer.cancel()
                        continuation.resume(throwing: makeError("Connection was cancelled."))
                    }

                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    // MARK: - Framing & Transport

    private static func sendFramedPacket(connection: NWConnection, payload: Data) async throws {
        var framed = Data(capacity: 4 + payload.count)
        let len = payload.count
        framed.append(0x00)
        framed.append(UInt8((len >> 16) & 0xff))
        framed.append(UInt8((len >> 8) & 0xff))
        framed.append(UInt8(len & 0xff))
        framed.append(payload)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func readExact(connection: NWConnection, count: Int) async throws -> Data {
        var accumulated = Data()
        while accumulated.count < count {
            let needed = count - accumulated.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: needed) { content, _, isComplete, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let content = content, !content.isEmpty {
                        continuation.resume(returning: content)
                    } else if isComplete {
                        continuation.resume(throwing: makeError("Connection closed unexpectedly by server."))
                    }
                }
            }
            accumulated.append(chunk)
        }
        return accumulated
    }

    private static func readFramedPacket(connection: NWConnection) async throws -> Data {
        var keepAlives = 0
        while true {
            let lengthHeader = try await readExact(connection: connection, count: 4)
            let msgType = lengthHeader[0]
            let length = (Int(lengthHeader[1]) << 16) | (Int(lengthHeader[2]) << 8) | Int(lengthHeader[3])

            // Discard NetBIOS Session Keep-Alive packets (RFC 1002 Section 4.3.5: type 0x85) or empty heartbeats
            if msgType == 0x85 || (msgType == 0 && length == 0) {
                keepAlives += 1
                if keepAlives > 20 {
                    throw makeError("Too many keep-alive frames received from SMB server.")
                }
                continue
            }

            guard length > 0 && length <= 1_048_576 else {
                throw makeError("Invalid SMB frame length: \(length)")
            }
            return try await readExact(connection: connection, count: length)
        }
    }

    private static func readCommandResponse(
        connection: NWConnection,
        expectedCommand: UInt16,
        messageId: UInt64
    ) async throws -> Data {
        var attempts = 0
        while attempts < 100 {
            attempts += 1
            let packet = try await readFramedPacket(connection: connection)
            guard let parsed = parseSMB2Header(data: packet) else {
                return packet
            }
            if parsed.status == 0x00000103 {
                // STATUS_PENDING - interim response, wait for final response
                continue
            }
            if parsed.messageId == messageId {
                return packet
            }
            // Discard mismatched messageId packet and keep waiting
        }
        throw makeError("Timed out waiting for SMB response for message ID \(messageId)")
    }

    // MARK: - SMB2 Packets

    private static func buildSMB2Header(
        command: UInt16,
        messageId: UInt64,
        sessionId: UInt64 = 0,
        treeId: UInt32 = 0,
        creditsRequested: UInt16 = 32
    ) -> Data {
        var header = Data(count: 64)
        header[0] = 0xfe; header[1] = 0x53; header[2] = 0x4d; header[3] = 0x42 // ProtocolId: \u{fe}SMB
        var structSize = UInt16(64).littleEndian
        header.replaceSubrange(4..<6, with: Data(bytes: &structSize, count: 2))
        var creditCharge: UInt16 = 0
        header.replaceSubrange(6..<8, with: Data(bytes: &creditCharge, count: 2))
        var cmd = command.littleEndian
        header.replaceSubrange(12..<14, with: Data(bytes: &cmd, count: 2))
        var credits = creditsRequested.littleEndian
        header.replaceSubrange(14..<16, with: Data(bytes: &credits, count: 2))
        var msgId = messageId.littleEndian
        header.replaceSubrange(24..<32, with: Data(bytes: &msgId, count: 8))
        var procId = UInt32(0xfeff).littleEndian
        header.replaceSubrange(32..<36, with: Data(bytes: &procId, count: 4))
        var tId = treeId.littleEndian
        header.replaceSubrange(36..<40, with: Data(bytes: &tId, count: 4))
        var sId = sessionId.littleEndian
        header.replaceSubrange(40..<48, with: Data(bytes: &sId, count: 8))
        return header
    }

    private static func parseSMB2Header(data: Data) -> (command: UInt16, status: UInt32, messageId: UInt64, sessionId: UInt64, treeId: UInt32)? {
        guard data.count >= 64,
              data[0] == 0xfe && data[1] == 0x53 && data[2] == 0x4d && data[3] == 0x42 else {
            return nil
        }
        let status = UInt32(data[8]) | (UInt32(data[9]) << 8) | (UInt32(data[10]) << 16) | (UInt32(data[11]) << 24)
        let command = UInt16(data[12]) | (UInt16(data[13]) << 8)
        let treeId = UInt32(data[36]) | (UInt32(data[37]) << 8) | (UInt32(data[38]) << 16) | (UInt32(data[39]) << 24)
        var sId: UInt64 = 0
        for i in 0..<8 {
            sId |= UInt64(data[40 + i]) << (i * 8)
        }
        var mId: UInt64 = 0
        for i in 0..<8 {
            mId |= UInt64(data[24 + i]) << (i * 8)
        }
        return (command, status, mId, sId, treeId)
    }

    private static func buildNegotiatePacket(messageId: UInt64) -> Data {
        let header = buildSMB2Header(command: 0, messageId: messageId)
        var body = Data()
        var structSize = UInt16(36).littleEndian
        body.append(Data(bytes: &structSize, count: 2))
        var dialectCount = UInt16(3).littleEndian
        body.append(Data(bytes: &dialectCount, count: 2))
        var securityMode = UInt16(0x01).littleEndian // SMB2_NEGOTIATE_SIGNING_ENABLED
        body.append(Data(bytes: &securityMode, count: 2))
        var reserved = UInt16(0)
        body.append(Data(bytes: &reserved, count: 2))
        var capabilities = UInt32(0)
        body.append(Data(bytes: &capabilities, count: 4))
        let clientGuid = UUID()
        withUnsafeBytes(of: clientGuid.uuid) { body.append(contentsOf: $0) }
        var startTime: UInt64 = 0
        body.append(Data(bytes: &startTime, count: 8))

        var d1 = UInt16(0x0202).littleEndian // SMB 2.0.2
        var d2 = UInt16(0x0210).littleEndian // SMB 2.1
        var d3 = UInt16(0x0300).littleEndian // SMB 3.0
        body.append(Data(bytes: &d1, count: 2))
        body.append(Data(bytes: &d2, count: 2))
        body.append(Data(bytes: &d3, count: 2))

        var packet = header
        packet.append(body)
        return packet
    }

    private static func buildSessionSetupPacket(messageId: UInt64, sessionId: UInt64, securityToken: Data) -> Data {
        let header = buildSMB2Header(command: 1, messageId: messageId, sessionId: sessionId)
        var body = Data()
        var structSize = UInt16(25).littleEndian
        body.append(Data(bytes: &structSize, count: 2))
        body.append(0x00) // Flags
        body.append(0x01) // SecurityMode
        var capabilities = UInt32(0)
        body.append(Data(bytes: &capabilities, count: 4))
        var channel = UInt32(0)
        body.append(Data(bytes: &channel, count: 4))

        // SecurityBufferOffset from start of SMB2 header (64 + 24 = 88)
        var secOffset = UInt16(88).littleEndian
        body.append(Data(bytes: &secOffset, count: 2))
        var secLen = UInt16(securityToken.count).littleEndian
        body.append(Data(bytes: &secLen, count: 2))
        var prevSessionId: UInt64 = 0
        body.append(Data(bytes: &prevSessionId, count: 8))

        var packet = header
        packet.append(body)
        packet.append(securityToken)
        return packet
    }

    private static func buildTreeConnectPacket(
        host: String,
        share: String,
        sessionId: UInt64,
        messageId: UInt64
    ) -> Data {
        let header = buildSMB2Header(command: 3, messageId: messageId, sessionId: sessionId)
        let fullPath = "\\\\\(host)\\\(share)"
        let pathData = toUTF16LE(fullPath)

        var body = Data()
        var structSize = UInt16(9).littleEndian
        body.append(Data(bytes: &structSize, count: 2))
        var reserved = UInt16(0)
        body.append(Data(bytes: &reserved, count: 2))
        var pathOffset = UInt16(72).littleEndian
        body.append(Data(bytes: &pathOffset, count: 2))
        var pathLen = UInt16(pathData.count).littleEndian
        body.append(Data(bytes: &pathLen, count: 2))
        body.append(pathData)

        var packet = header
        packet.append(body)
        return packet
    }

    private static func extractSecurityBuffer(from smbPacket: Data) -> Data? {
        guard smbPacket.count >= 72 else { return nil }
        let secOffset = Int(UInt16(smbPacket[68]) | (UInt16(smbPacket[69]) << 8))
        let secLen = Int(UInt16(smbPacket[70]) | (UInt16(smbPacket[71]) << 8))
        guard secOffset + secLen <= smbPacket.count else { return nil }
        return smbPacket.subdata(in: secOffset ..< (secOffset + secLen))
    }

    private static func checkIfSPNEGO(_ smbPacket: Data) -> Bool {
        guard let secBuffer = extractSecurityBuffer(from: smbPacket), !secBuffer.isEmpty else {
            return false
        }
        return secBuffer[0] == 0x60 || secBuffer[0] == 0xa1
    }

    // MARK: - NTLMSSP Implementation

    private static func buildNTLMSSPNegotiate() -> Data {
        var data = Data()
        data.append(contentsOf: [0x4e, 0x54, 0x4c, 0x4d, 0x53, 0x53, 0x50, 0x00]) // "NTLMSSP\0"
        var msgType = UInt32(1).littleEndian
        data.append(Data(bytes: &msgType, count: 4))
        // Flags: NTLMSSP_NEGOTIATE_UNICODE | NTLMSSP_REQUEST_TARGET | NTLMSSP_NEGOTIATE_NTLM | NTLMSSP_NEGOTIATE_ALWAYS_SIGN | NTLMSSP_NEGOTIATE_EXTENDED_SESSIONSECURITY | NTLMSSP_NEGOTIATE_128 | NTLMSSP_NEGOTIATE_56
        var flags = UInt32(0xA0088205).littleEndian
        data.append(Data(bytes: &flags, count: 4))
        // Domain
        var dLen = UInt16(0), dMax = UInt16(0), dOff = UInt32(32).littleEndian
        data.append(Data(bytes: &dLen, count: 2))
        data.append(Data(bytes: &dMax, count: 2))
        data.append(Data(bytes: &dOff, count: 4))
        // Workstation
        var wLen = UInt16(0), wMax = UInt16(0), wOff = UInt32(32).littleEndian
        data.append(Data(bytes: &wLen, count: 2))
        data.append(Data(bytes: &wMax, count: 2))
        data.append(Data(bytes: &wOff, count: 4))
        return data
    }

    private static func parseNTLMSSPChallenge(securityBuffer: Data) -> (serverChallenge: Data, targetInfo: Data?)? {
        let ntlmMagic: [UInt8] = [0x4e, 0x54, 0x4c, 0x4d, 0x53, 0x53, 0x50, 0x00]
        guard let idx = securityBuffer.firstRange(of: Data(ntlmMagic))?.lowerBound else {
            return nil
        }
        let ntlm = securityBuffer.subdata(in: idx ..< securityBuffer.count)
        guard ntlm.count >= 32 else { return nil }
        let challenge = ntlm.subdata(in: 24..<32)

        var targetInfo: Data? = nil
        if ntlm.count >= 48 {
            let tiLen = Int(UInt16(ntlm[40]) | (UInt16(ntlm[41]) << 8))
            let tiOff = Int(UInt32(ntlm[44]) | (UInt32(ntlm[45]) << 8) | (UInt32(ntlm[46]) << 16) | (UInt32(ntlm[47]) << 24))
            if tiLen > 0 && tiOff + tiLen <= ntlm.count {
                targetInfo = ntlm.subdata(in: tiOff ..< (tiOff + tiLen))
            }
        }

        return (challenge, targetInfo)
    }

    private static func extractTargetInfoTimestamp(targetInfo: Data) -> UInt64? {
        var offset = 0
        while offset + 4 <= targetInfo.count {
            let avId = UInt16(targetInfo[offset]) | (UInt16(targetInfo[offset + 1]) << 8)
            let avLen = Int(UInt16(targetInfo[offset + 2]) | (UInt16(targetInfo[offset + 3]) << 8))
            offset += 4
            if avId == 0x0000 { break } // MsvAvEOL
            if avId == 0x0007 && avLen == 8 && offset + 8 <= targetInfo.count {
                var ts: UInt64 = 0
                for i in 0..<8 {
                    ts |= UInt64(targetInfo[offset + i]) << (i * 8)
                }
                return ts
            }
            offset += avLen
        }
        return nil
    }

    private static func extractTargetInfoDomain(targetInfo: Data) -> String? {
        var offset = 0
        while offset + 4 <= targetInfo.count {
            let avId = UInt16(targetInfo[offset]) | (UInt16(targetInfo[offset + 1]) << 8)
            let avLen = Int(UInt16(targetInfo[offset + 2]) | (UInt16(targetInfo[offset + 3]) << 8))
            offset += 4
            if avId == 0x0000 { break }
            if (avId == 0x0002 || avId == 0x0001) && offset + avLen <= targetInfo.count {
                let slice = targetInfo.subdata(in: offset ..< (offset + avLen))
                let chars = stride(from: 0, to: slice.count, by: 2).compactMap { i -> Character? in
                    if i + 1 < slice.count {
                        let u16 = UInt16(slice[i]) | (UInt16(slice[i + 1]) << 8)
                        return Character(UnicodeScalar(u16) ?? UnicodeScalar(0x20)!)
                    }
                    return nil
                }
                let domainStr = String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
                if !domainStr.isEmpty {
                    return domainStr
                }
            }
            offset += avLen
        }
        return nil
    }

    private static func buildNTLMSSPAuthenticate(
        destination: SambaDestination,
        serverChallenge: Data,
        targetInfo: Data?
    ) -> Data {
        if destination.isGuest {
            // Anonymous authentication: NTLMSSP_NEGOTIATE_ANONYMOUS
            return buildType3Payload(
                domain: "",
                user: "",
                workstation: "",
                lmResponse: Data(),
                ntResponse: Data(),
                isGuest: true
            )
        }

        var domain = ""
        var user = destination.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slashIdx = user.firstIndex(of: "\\") {
            domain = String(user[..<slashIdx])
            user = String(user[user.index(after: slashIdx)...])
        } else if let atIdx = user.firstIndex(of: "@") {
            domain = String(user[user.index(after: atIdx)...])
            user = String(user[..<atIdx])
        }

        if domain.isEmpty, let ti = targetInfo {
            if let serverDomain = extractTargetInfoDomain(targetInfo: ti) {
                domain = serverDomain
            }
        }

        let password = destination.password

        // NTLMv2 computation
        let passwordHash = md4(toUTF16LE(password))
        let userAndDomain = toUTF16LE(user.uppercased() + domain)
        let ntlmv2Hash = hmacMD5(key: passwordHash, data: userAndDomain)

        // Build client blob (NTLMv2_CLIENT_CHALLENGE)
        var clientBlob = Data()
        clientBlob.append(contentsOf: [0x01, 0x01, 0x00, 0x00]) // Signature: 0x01010000
        clientBlob.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // Reserved: 0

        // Timestamp: prioritize server's timestamp from targetInfo if provided
        let serverTimestamp = targetInfo.flatMap { extractTargetInfoTimestamp(targetInfo: $0) }
        let fileTime = serverTimestamp ?? UInt64((Date().timeIntervalSince1970 + 11644473600.0) * 10_000_000.0)
        var ftLE = fileTime.littleEndian
        clientBlob.append(Data(bytes: &ftLE, count: 8))

        // Client Nonce (8 random bytes)
        var clientNonce = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, 8, &clientNonce)
        clientBlob.append(contentsOf: clientNonce)

        clientBlob.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // Reserved: 0

        // TargetInfo (ends with MsvAvEOL [0x00, 0x00, 0x00, 0x00])
        if let ti = targetInfo, !ti.isEmpty {
            clientBlob.append(ti)
        } else {
            clientBlob.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        }

        // NTProofStr = HMAC-MD5(ntlmv2Hash, serverChallenge + clientBlob)
        var ntData = serverChallenge
        ntData.append(clientBlob)
        let ntProofStr = hmacMD5(key: ntlmv2Hash, data: ntData)

        var ntResponse = ntProofStr
        ntResponse.append(clientBlob)

        // LMv2 Response = HMAC-MD5(ntlmv2Hash, serverChallenge + clientNonce) + clientNonce
        var lmData = serverChallenge
        lmData.append(contentsOf: clientNonce)
        var lmResponse = hmacMD5(key: ntlmv2Hash, data: lmData)
        lmResponse.append(contentsOf: clientNonce)

        return buildType3Payload(
            domain: domain,
            user: user,
            workstation: "PHOTOEXPORTER",
            lmResponse: lmResponse,
            ntResponse: ntResponse,
            isGuest: false
        )
    }

    private static func buildType3Payload(
        domain: String,
        user: String,
        workstation: String,
        lmResponse: Data,
        ntResponse: Data,
        isGuest: Bool
    ) -> Data {
        var data = Data()
        data.append(contentsOf: [0x4e, 0x54, 0x4c, 0x4d, 0x53, 0x53, 0x50, 0x00]) // "NTLMSSP\0"
        var msgType = UInt32(3).littleEndian
        data.append(Data(bytes: &msgType, count: 4))

        let domainData = toUTF16LE(domain)
        let userData = toUTF16LE(user)
        let wsData = toUTF16LE(workstation)

        var payloadOffset = UInt32(64)

        func appendField(len: Int) {
            var l = UInt16(len).littleEndian
            var m = UInt16(len).littleEndian
            var o = payloadOffset.littleEndian
            data.append(Data(bytes: &l, count: 2))
            data.append(Data(bytes: &m, count: 2))
            data.append(Data(bytes: &o, count: 4))
            payloadOffset += UInt32(len)
        }

        // 12..20: LM Response
        appendField(len: lmResponse.count)
        // 20..28: NT Response
        appendField(len: ntResponse.count)
        // 28..36: Domain
        appendField(len: domainData.count)
        // 36..44: User
        appendField(len: userData.count)
        // 44..52: Workstation
        appendField(len: wsData.count)
        // 52..60: Session Key (0 length, offset at payload end)
        appendField(len: 0)

        // 60..64: Flags (Clean standard flags without KEY_EXCH and without VERSION)
        var flags: UInt32 = isGuest ? UInt32(0x00008A05).littleEndian : UInt32(0xA0088205).littleEndian
        data.append(Data(bytes: &flags, count: 4))

        data.append(lmResponse)
        data.append(ntResponse)
        data.append(domainData)
        data.append(userData)
        data.append(wsData)

        return data
    }

    // MARK: - SPNEGO ASN.1 Wrappers

    private static func asn1Tag(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var result = [tag]
        let count = content.count
        if count < 128 {
            result.append(UInt8(count))
        } else if count < 256 {
            result.append(0x81)
            result.append(UInt8(count))
        } else {
            result.append(0x82)
            result.append(UInt8((count >> 8) & 0xff))
            result.append(UInt8(count & 0xff))
        }
        result.append(contentsOf: content)
        return result
    }

    private static func asn1Sequence(_ content: [UInt8]) -> [UInt8] {
        return asn1Tag(0x30, content)
    }

    private static func wrapSPNEGONegTokenInit(ntlmToken: Data) -> Data {
        let mechTypesOid: [UInt8] = [0x06, 0x0a, 0x2b, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x0a]
        let mechTypesSeq = asn1Sequence(mechTypesOid)
        let mechTypesTagged = asn1Tag(0xa0, mechTypesSeq)

        let mechTokenOctet = asn1Tag(0x04, [UInt8](ntlmToken))
        let mechTokenTagged = asn1Tag(0xa2, mechTokenOctet)

        var inner = mechTypesTagged
        inner.append(contentsOf: mechTokenTagged)
        let negTokenInitSeq = asn1Sequence(inner)
        let negTokenInitTagged = asn1Tag(0xa0, negTokenInitSeq)

        let spnegoOid: [UInt8] = [0x06, 0x06, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x02]
        var app0 = spnegoOid
        app0.append(contentsOf: negTokenInitTagged)
        return Data(asn1Tag(0x60, app0))
    }

    private static func wrapSPNEGONegTokenResp(ntlmToken: Data) -> Data {
        let respTokenOctet = asn1Tag(0x04, [UInt8](ntlmToken))
        let respTokenTagged = asn1Tag(0xa2, respTokenOctet)
        let seq = asn1Sequence(respTokenTagged)
        return Data(asn1Tag(0xa1, seq))
    }

    // MARK: - Crypto & Encoding Utilities

    private static func toUTF16LE(_ str: String) -> Data {
        let chars = Array(str.utf16)
        var data = Data(capacity: chars.count * 2)
        for ch in chars {
            var le = ch.littleEndian
            data.append(Data(bytes: &le, count: 2))
        }
        return data
    }

    private static func hmacMD5(key: Data, data: Data) -> Data {
        var result = [UInt8](repeating: 0, count: 16)
        key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgMD5),
                    keyBytes.baseAddress,
                    key.count,
                    dataBytes.baseAddress,
                    data.count,
                    &result
                )
            }
        }
        return Data(result)
    }

    private static func md4(_ data: Data) -> Data {
        var message = data
        let bitLen = UInt64(data.count) * 8
        message.append(0x80)
        while (message.count % 64) != 56 {
            message.append(0x00)
        }
        var lenBytes = bitLen.littleEndian
        message.append(Data(bytes: &lenBytes, count: 8))

        var a: UInt32 = 0x67452301
        var b: UInt32 = 0xefcdab89
        var c: UInt32 = 0x98badcfe
        var d: UInt32 = 0x10325476

        func f(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (~x & z) }
        func g(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (x & z) | (y & z) }
        func h(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x ^ y ^ z }
        func rot(_ x: UInt32, _ s: UInt32) -> UInt32 { (x << s) | (x >> (32 - s)) }

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            let chunk = message.subdata(in: chunkStart..<(chunkStart + 64))
            var x = [UInt32](repeating: 0, count: 16)
            chunk.withUnsafeBytes { ptr in
                for i in 0..<16 {
                    x[i] = ptr.load(fromByteOffset: i * 4, as: UInt32.self).littleEndian
                }
            }

            let aa = a; let bb = b; let cc = c; let dd = d

            a = rot(a &+ f(b, c, d) &+ x[0], 3); d = rot(d &+ f(a, b, c) &+ x[1], 7); c = rot(c &+ f(d, a, b) &+ x[2], 11); b = rot(b &+ f(c, d, a) &+ x[3], 19)
            a = rot(a &+ f(b, c, d) &+ x[4], 3); d = rot(d &+ f(a, b, c) &+ x[5], 7); c = rot(c &+ f(d, a, b) &+ x[6], 11); b = rot(b &+ f(c, d, a) &+ x[7], 19)
            a = rot(a &+ f(b, c, d) &+ x[8], 3); d = rot(d &+ f(a, b, c) &+ x[9], 7); c = rot(c &+ f(d, a, b) &+ x[10], 11); b = rot(b &+ f(c, d, a) &+ x[11], 19)
            a = rot(a &+ f(b, c, d) &+ x[12], 3); d = rot(d &+ f(a, b, c) &+ x[13], 7); c = rot(c &+ f(d, a, b) &+ x[14], 11); b = rot(b &+ f(c, d, a) &+ x[15], 19)

            let k2: UInt32 = 0x5a827999
            a = rot(a &+ g(b, c, d) &+ x[0] &+ k2, 3); d = rot(d &+ g(a, b, c) &+ x[4] &+ k2, 5); c = rot(c &+ g(d, a, b) &+ x[8] &+ k2, 9); b = rot(b &+ g(c, d, a) &+ x[12] &+ k2, 13)
            a = rot(a &+ g(b, c, d) &+ x[1] &+ k2, 3); d = rot(d &+ g(a, b, c) &+ x[5] &+ k2, 5); c = rot(c &+ g(d, a, b) &+ x[9] &+ k2, 9); b = rot(b &+ g(c, d, a) &+ x[13] &+ k2, 13)
            a = rot(a &+ g(b, c, d) &+ x[2] &+ k2, 3); d = rot(d &+ g(a, b, c) &+ x[6] &+ k2, 5); c = rot(c &+ g(d, a, b) &+ x[10] &+ k2, 9); b = rot(b &+ g(c, d, a) &+ x[14] &+ k2, 13)
            a = rot(a &+ g(b, c, d) &+ x[3] &+ k2, 3); d = rot(d &+ g(a, b, c) &+ x[7] &+ k2, 5); c = rot(c &+ g(d, a, b) &+ x[11] &+ k2, 9); b = rot(b &+ g(c, d, a) &+ x[15] &+ k2, 13)

            let k3: UInt32 = 0x6ed9eba1
            a = rot(a &+ h(b, c, d) &+ x[0] &+ k3, 3); d = rot(d &+ h(a, b, c) &+ x[8] &+ k3, 9); c = rot(c &+ h(d, a, b) &+ x[4] &+ k3, 11); b = rot(b &+ h(c, d, a) &+ x[12] &+ k3, 15)
            a = rot(a &+ h(b, c, d) &+ x[2] &+ k3, 3); d = rot(d &+ h(a, b, c) &+ x[10] &+ k3, 9); c = rot(c &+ h(d, a, b) &+ x[6] &+ k3, 11); b = rot(b &+ h(c, d, a) &+ x[14] &+ k3, 15)
            a = rot(a &+ h(b, c, d) &+ x[1] &+ k3, 3); d = rot(d &+ h(a, b, c) &+ x[9] &+ k3, 9); c = rot(c &+ h(d, a, b) &+ x[5] &+ k3, 11); b = rot(b &+ h(c, d, a) &+ x[13] &+ k3, 15)
            a = rot(a &+ h(b, c, d) &+ x[3] &+ k3, 3); d = rot(d &+ h(a, b, c) &+ x[11] &+ k3, 9); c = rot(c &+ h(d, a, b) &+ x[7] &+ k3, 11); b = rot(b &+ h(c, d, a) &+ x[15] &+ k3, 15)

            a = a &+ aa; b = b &+ bb; c = c &+ cc; d = d &+ dd
        }

        var result = Data()
        var wa = a.littleEndian; var wb = b.littleEndian; var wc = c.littleEndian; var wd = d.littleEndian
        result.append(Data(bytes: &wa, count: 4))
        result.append(Data(bytes: &wb, count: 4))
        result.append(Data(bytes: &wc, count: 4))
        result.append(Data(bytes: &wd, count: 4))
        return result
    }

    nonisolated static func describeStatus(_ status: UInt32) -> String {
        switch status {
        case 0xC000006D: return "STATUS_LOGON_FAILURE (0xC000006D: Incorrect username or password)"
        case 0xC0000022: return "STATUS_ACCESS_DENIED (0xC0000022: Access denied)"
        case 0xC00000CC: return "STATUS_BAD_NETWORK_NAME (0xC00000CC: Share not found)"
        case 0xC000006E: return "STATUS_ACCOUNT_RESTRICTION (0xC000006E: Account restriction)"
        case 0xC0000071: return "STATUS_PASSWORD_EXPIRED (0xC0000071: Password expired)"
        case 0xC0000072: return "STATUS_ACCOUNT_DISABLED (0xC0000072: Account disabled)"
        case 0xC0000034: return "STATUS_OBJECT_NAME_NOT_FOUND (0xC0000034: Not found)"
        case 0xC0000035: return "STATUS_OBJECT_NAME_COLLISION (0xC0000035: Already exists)"
        case 0xC000000D: return "STATUS_INVALID_PARAMETER (0xC000000D: Invalid parameter)"
        default: return String(format: "0x%08X", status)
        }
    }

    nonisolated static func makeError(_ message: String) -> NSError {
        return NSError(domain: "SMB2Client", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private struct SMBDirectoryEntry {
    let name: String
    let isDirectory: Bool
    let modificationDate: Date?
    let fileSize: Int64
}

/// Active, authenticated SMB2 session connected to a share, capable of listing directories, creating files, and uploading data
final class SMB2ClientSession {
    let connection: NWConnection
    let host: String
    let sessionId: UInt64
    let treeId: UInt32
    private var messageId: UInt64

    var isReadyForReuse: Bool {
        connection.state == .ready
    }

    init(connection: NWConnection, host: String, sessionId: UInt64, treeId: UInt32, initialMessageId: UInt64) {
        self.connection = connection
        self.host = host
        self.sessionId = sessionId
        self.treeId = treeId
        self.messageId = initialMessageId
    }

    private func nextMessageId() -> UInt64 {
        let current = messageId
        messageId += 1
        return current
    }

    private func readCommandResponse(expectedCommand: UInt16, messageId: UInt64) async throws -> Data {
        var attempts = 0
        while attempts < 100 {
            attempts += 1
            let packet = try await readFramedPacket()
            guard let parsed = parseSMB2Header(data: packet) else {
                return packet
            }
            if parsed.status == 0x00000103 {
                // STATUS_PENDING - interim response from server, wait for the final completion packet
                continue
            }
            if parsed.messageId == messageId {
                return packet
            }
            // Discard mismatched messageId packet from an earlier operation and keep reading
        }
        throw SMB2Client.makeError("Timed out waiting for SMB response for message ID \(messageId)")
    }

    func ensureDirectory(path: String) async throws {
        let clean = path.replacingOccurrences(of: "/", with: "\\").trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
        guard !clean.isEmpty else { return }
        let components = clean.split(separator: "\\").map(String.init)
        var cumulative = ""
        for comp in components {
            if !cumulative.isEmpty { cumulative += "\\" }
            cumulative += comp
            try? await createDirectory(relativePath: cumulative)
        }
    }

    /// Creates a new subdirectory at the given share-relative path, failing if it already exists or permission is denied
    func createSubdirectory(path: String) async throws {
        let clean = path.replacingOccurrences(of: "/", with: "\\").trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
        guard !clean.isEmpty else {
            throw SMB2Client.makeError("Folder name cannot be empty.")
        }
        try await createDirectory(relativePath: clean, disposition: 2) // FILE_CREATE
    }

    private func createDirectory(relativePath: String, disposition: UInt32 = 3) async throws {
        let msgId = nextMessageId()
        let req = buildCreatePacket(
            filePath: relativePath,
            isDirectory: true,
            disposition: disposition,
            sessionId: sessionId,
            treeId: treeId,
            messageId: msgId
        )
        try await sendFramedPacket(payload: req)
        let resp = try await readCommandResponse(expectedCommand: 5, messageId: msgId)
        let parsed = parseSMB2Header(data: resp)
        guard let parsed else {
            throw SMB2Client.makeError("Failed to parse folder creation response for '\(relativePath)'.")
        }
        guard parsed.status == 0, resp.count >= 144 else {
            throw SMB2Client.makeError("Failed to create folder '\(relativePath)': \(SMB2Client.describeStatus(parsed.status))")
        }
        let fileId = resp.subdata(in: 128..<144)
        try? await closeFile(fileId: fileId)
    }

    /// Rename a remote file using SMB2 SET_INFO (FileRenameInformation)
    func renameFile(from oldRelativePath: String, to newRelativePath: String, replaceIfExists: Bool = false) async throws {
        let openMsgId = nextMessageId()
        let openReq = buildCreatePacket(
            filePath: oldRelativePath,
            isDirectory: false,
            disposition: 1, // FILE_OPEN
            desiredAccess: 0x00110080, // DELETE | FILE_READ_ATTRIBUTES | SYNCHRONIZE
            sessionId: sessionId,
            treeId: treeId,
            messageId: openMsgId
        )
        try await sendFramedPacket(payload: openReq)
        let openResp = try await readCommandResponse(expectedCommand: 5, messageId: openMsgId)
        let openParsed = parseSMB2Header(data: openResp)
        guard let openParsed, openParsed.status == 0, openResp.count >= 144 else {
            let statusDesc = openParsed != nil ? SMB2Client.describeStatus(openParsed!.status) : "Invalid SMB Header"
            throw SMB2Client.makeError("Failed to open '\(oldRelativePath)' for rename: \(statusDesc)")
        }
        let fileId = openResp.subdata(in: 128..<144)

        let setMsgId = nextMessageId()
        let setReq = buildSetRenameInfoPacket(
            fileId: fileId,
            newRelativePath: newRelativePath,
            replaceIfExists: replaceIfExists,
            sessionId: sessionId,
            treeId: treeId,
            messageId: setMsgId
        )
        do {
            try await sendFramedPacket(payload: setReq)
            let setResp = try await readCommandResponse(expectedCommand: 17, messageId: setMsgId)
            try? await closeFile(fileId: fileId)
            if let setParsed = parseSMB2Header(data: setResp), setParsed.status != 0 {
                throw SMB2Client.makeError("Failed to rename '\(oldRelativePath)': \(SMB2Client.describeStatus(setParsed.status))")
            }
        } catch {
            try? await closeFile(fileId: fileId)
            throw error
        }
    }

    /// Fast listing of files in a directory using SMB2 QUERY_DIRECTORY
    func listDirectory(path: String) async throws -> Set<String> {
        let details = try await listDirectoryDetails(path: path)
        return Set(details.map(\.filename))
    }

    /// Lists directory files with metadata (modification date and file size) for deduplication checking
    func listDirectoryDetails(path: String) async throws -> [DestinationFileInfo] {
        try await listDirectoryEntries(path: path, throwOnOpenError: false).files
    }

    /// Lists both subdirectories and non-empty files with metadata in a single directory scan.
    func listDirectoryEntries(path: String, throwOnOpenError: Bool = true) async throws -> (folders: [DestinationFileInfo], files: [DestinationFileInfo]) {
        let entries = try await queryDirectoryEntries(path: path, throwOnOpenError: throwOnOpenError)
        var folders: [DestinationFileInfo] = []
        var files: [DestinationFileInfo] = []
        for entry in entries {
            if entry.isDirectory {
                folders.append(DestinationFileInfo(
                    id: entry.name,
                    filename: entry.name,
                    modificationDate: entry.modificationDate,
                    fileSize: 0,
                    thumbnailLink: nil
                ))
            } else if entry.fileSize > 0 {
                files.append(DestinationFileInfo(
                    id: entry.name,
                    filename: entry.name,
                    modificationDate: entry.modificationDate,
                    fileSize: entry.fileSize,
                    thumbnailLink: nil
                ))
            }
        }
        return (folders, files)
    }

    /// Lists subdirectory names and supported media counts inside the given share-relative path
    func listDirectoryContents(path: String) async throws -> (subfolders: [String], imageCount: Int, videoCount: Int) {
        let entries = try await queryDirectoryEntries(path: path, throwOnOpenError: true)
        let subfolders = entries
            .filter(\.isDirectory)
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let mediaCounts = PhotoItem.countMediaFilenames(
            entries.lazy.filter { !$0.isDirectory && $0.fileSize > 0 }.map(\.name)
        )
        return (subfolders, mediaCounts.images, mediaCounts.videos)
    }

    /// Lists subdirectory names inside the given share-relative path, sorted alphabetically
    func listSubdirectories(path: String) async throws -> [String] {
        try await listDirectoryContents(path: path).subfolders
    }

    private func queryDirectoryEntries(path: String, throwOnOpenError: Bool) async throws -> [SMBDirectoryEntry] {
        let clean = path.replacingOccurrences(of: "/", with: "\\").trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
        let dirMsgId = nextMessageId()
        let req = buildCreatePacket(
            filePath: clean,
            isDirectory: true,
            disposition: 1, // FILE_OPEN
            desiredAccess: 0x00100021, // FILE_LIST_DIRECTORY | SYNCHRONIZE
            sessionId: sessionId,
            treeId: treeId,
            messageId: dirMsgId
        )
        try await sendFramedPacket(payload: req)
        let resp = try await readCommandResponse(expectedCommand: 5, messageId: dirMsgId)
        let parsed = parseSMB2Header(data: resp)
        guard let parsed, parsed.status == 0, resp.count >= 144 else {
            if throwOnOpenError {
                let statusDesc = parsed.map { SMB2Client.describeStatus($0.status) } ?? "Invalid SMB response"
                let folderLabel = clean.isEmpty ? "share root" : "'\(clean)'"
                throw SMB2Client.makeError("Failed to open \(folderLabel): \(statusDesc)")
            }
            return []
        }
        let dirFileId = resp.subdata(in: 128..<144)

        var results: [SMBDirectoryEntry] = []
        var restartScan = true

        do {
            while true {
                let qMsgId = nextMessageId()
                let queryReq = buildQueryDirectoryPacket(
                    dirFileId: dirFileId,
                    pattern: "*",
                    restartScan: restartScan,
                    sessionId: sessionId,
                    treeId: treeId,
                    messageId: qMsgId
                )
                restartScan = false
                try await sendFramedPacket(payload: queryReq)
                let qResp = try await readCommandResponse(expectedCommand: 14, messageId: qMsgId)
                guard let qParsed = parseSMB2Header(data: qResp) else { break }

                if qParsed.status == 0x80000006 { // STATUS_NO_MORE_FILES
                    break
                }
                guard qParsed.status == 0 else { break }
                guard qResp.count >= 72 else { break }

                let outOffset = Int(UInt16(qResp[66]) | (UInt16(qResp[67]) << 8))
                let outLength = Int(UInt32(qResp[68]) | (UInt32(qResp[69]) << 8) | (UInt32(qResp[70]) << 16) | (UInt32(qResp[71]) << 24))

                guard outOffset >= 64, outOffset + outLength <= qResp.count, outLength >= 64 else { break }

                var entryOffset = outOffset
                let endOffset = outOffset + outLength

                while entryOffset + 64 <= endOffset {
                    let nextOffset = Int(UInt32(qResp[entryOffset]) | (UInt32(qResp[entryOffset + 1]) << 8) | (UInt32(qResp[entryOffset + 2]) << 16) | (UInt32(qResp[entryOffset + 3]) << 24))

                    // LastWriteTime at offset 24 (8 bytes, FILETIME: 100ns since 1601-01-01 UTC)
                    var rawLastWrite: UInt64 = 0
                    _ = withUnsafeMutableBytes(of: &rawLastWrite) { destPtr in
                        qResp.copyBytes(to: destPtr, from: (entryOffset + 24)..<(entryOffset + 32))
                    }
                    let lastWriteTime = UInt64(littleEndian: rawLastWrite)
                    var modDate: Date? = nil
                    if lastWriteTime > 116444736000000000 {
                        let seconds = Double(lastWriteTime - 116444736000000000) / 10_000_000.0
                        modDate = Date(timeIntervalSince1970: seconds)
                    }

                    // EndOfFile at offset 40 (8 bytes, Int64: file size)
                    var rawEndOfFile: Int64 = 0
                    _ = withUnsafeMutableBytes(of: &rawEndOfFile) { destPtr in
                        qResp.copyBytes(to: destPtr, from: (entryOffset + 40)..<(entryOffset + 48))
                    }
                    var fileSize = max(0, Int64(littleEndian: rawEndOfFile))

                    // If EndOfFile is 0, check AllocationSize at offset 48 (8 bytes) as fallback (for servers reporting unflushed buffers)
                    if fileSize == 0 {
                        var rawAllocSize: Int64 = 0
                        _ = withUnsafeMutableBytes(of: &rawAllocSize) { destPtr in
                            qResp.copyBytes(to: destPtr, from: (entryOffset + 48)..<(entryOffset + 56))
                        }
                        let allocSize = max(0, Int64(littleEndian: rawAllocSize))
                        if allocSize > 0 {
                            fileSize = allocSize
                        }
                    }

                    // FileAttributes at offset 56 (4 bytes, UInt32)
                    var rawAttrs: UInt32 = 0
                    _ = withUnsafeMutableBytes(of: &rawAttrs) { destPtr in
                        qResp.copyBytes(to: destPtr, from: (entryOffset + 56)..<(entryOffset + 60))
                    }
                    let isDirectory = (UInt32(littleEndian: rawAttrs) & 0x10) != 0

                    let nameLen = Int(UInt32(qResp[entryOffset + 60]) | (UInt32(qResp[entryOffset + 61]) << 8) | (UInt32(qResp[entryOffset + 62]) << 16) | (UInt32(qResp[entryOffset + 63]) << 24))

                    if nameLen > 0 && entryOffset + 64 + nameLen <= qResp.count {
                        let nameData = qResp.subdata(in: (entryOffset + 64)..<(entryOffset + 64 + nameLen))
                        if let filename = String(data: nameData, encoding: .utf16LittleEndian),
                           filename != "." && filename != ".." {
                            results.append(SMBDirectoryEntry(
                                name: filename,
                                isDirectory: isDirectory,
                                modificationDate: modDate,
                                fileSize: fileSize
                            ))
                        }
                    }

                    if nextOffset == 0 { break }
                    entryOffset += nextOffset
                }
            }
            try? await closeFile(fileId: dirFileId)
            return results
        } catch {
            try? await closeFile(fileId: dirFileId)
            throw error
        }
    }

    // MARK: - Share Enumeration (SRVSVC over IPC$)

    /// Enumerates visible non-hidden disk shares using an IPC$ session and the \srvsvc named pipe
    func listShares() async throws -> [String] {
        let pipeFileId = try await openNamedPipe(name: "srvsvc")
        do {
            var pipeReadBuffer = Data()

            // Bind to SRVSVC v3.0 (UUID 4b324fc8-1670-01d3-1278-5a47bf6ee188)
            try await writeChunk(fileId: pipeFileId, offset: 0, chunk: buildSRVSVCBindPacket(callId: 1))
            let bindAck = try await readDCERPCPDU(pipeFileId: pipeFileId, buffer: &pipeReadBuffer)
            guard bindAck.count >= 24, bindAck[2] == 12 else {
                let ptype = bindAck.count >= 3 ? bindAck[2] : 0
                throw SMB2Client.makeError("SMB server rejected share enumeration bind (RPC type \(ptype)).")
            }

            var collectedShares: [String] = []
            var resumeHandle: UInt32 = 0
            var callId: UInt32 = 2
            var pages = 0

            while pages < 20 {
                pages += 1
                let reqPDU = buildNetrShareEnumRequest(callId: callId, resumeHandle: resumeHandle)
                callId += 1
                try await writeChunk(fileId: pipeFileId, offset: 0, chunk: reqPDU)

                let responseStub = try await readDCERPCResponseStub(pipeFileId: pipeFileId, buffer: &pipeReadBuffer)
                let parsed = try parseNetrShareEnumResponse(stub: responseStub)
                collectedShares.append(contentsOf: parsed.shares)

                if parsed.status == 0 {
                    break
                } else if parsed.status == 234, let nextHandle = parsed.nextResumeHandle, nextHandle != 0 {
                    resumeHandle = nextHandle
                } else if parsed.status == 5 {
                    throw SMB2Client.makeError("Access denied while listing shares on the SMB server.")
                } else {
                    throw SMB2Client.makeError("Failed to list SMB shares (status \(parsed.status)).")
                }
            }

            try? await closeFile(fileId: pipeFileId)
            return Array(Set(collectedShares)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            try? await closeFile(fileId: pipeFileId)
            throw error
        }
    }

    private func openNamedPipe(name: String) async throws -> Data {
        let msgId = nextMessageId()
        let req = buildCreatePacket(
            filePath: name,
            isDirectory: false,
            disposition: 1, // FILE_OPEN
            desiredAccess: 0x0012019F, // FILE_READ_DATA | FILE_WRITE_DATA | FILE_APPEND_DATA | READ_CONTROL | SYNCHRONIZE
            createOptions: 0x00000060, // FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT
            sessionId: sessionId,
            treeId: treeId,
            messageId: msgId
        )
        try await sendFramedPacket(payload: req)
        let resp = try await readCommandResponse(expectedCommand: 5, messageId: msgId)
        let parsed = parseSMB2Header(data: resp)
        guard let parsed else {
            throw SMB2Client.makeError("Failed to parse SMB pipe open response for '\(name)'.")
        }
        guard parsed.status == 0, resp.count >= 144 else {
            throw SMB2Client.makeError("Cannot open '\(name)' service pipe on server: \(SMB2Client.describeStatus(parsed.status))")
        }
        return resp.subdata(in: 128..<144)
    }

    private func readPipeChunk(fileId: Data, length: UInt32 = 8192) async throws -> Data {
        let msgId = nextMessageId()
        let req = buildReadPacket(
            fileId: fileId,
            offset: 0,
            length: length,
            sessionId: sessionId,
            treeId: treeId,
            messageId: msgId
        )
        try await sendFramedPacket(payload: req)
        let resp = try await readCommandResponse(expectedCommand: 8, messageId: msgId)
        guard let parsed = parseSMB2Header(data: resp) else {
            throw SMB2Client.makeError("Failed to parse SMB pipe read response.")
        }
        guard parsed.status == 0 || parsed.status == 0x80000005 else {
            throw SMB2Client.makeError("Failed reading RPC response from SMB server: \(SMB2Client.describeStatus(parsed.status))")
        }
        guard resp.count >= 72 else {
            throw SMB2Client.makeError("Truncated SMB pipe read response.")
        }
        let dataOffset = Int(resp[66])
        let dataLength = Int(UInt32(resp[68]) | (UInt32(resp[69]) << 8) | (UInt32(resp[70]) << 16) | (UInt32(resp[71]) << 24))
        guard dataOffset >= 64, dataOffset + dataLength <= resp.count else {
            return Data()
        }
        return resp.subdata(in: dataOffset..<(dataOffset + dataLength))
    }

    private func readDCERPCPDU(pipeFileId: Data, buffer: inout Data) async throws -> Data {
        while buffer.count < 16 {
            let chunk = try await readPipeChunk(fileId: pipeFileId)
            if chunk.isEmpty {
                throw SMB2Client.makeError("Unexpected end of RPC stream from SMB server.")
            }
            buffer.append(chunk)
        }

        let start = buffer.startIndex
        let fragLength = Int(UInt16(buffer[start + 8]) | (UInt16(buffer[start + 9]) << 8))
        guard fragLength >= 16 else {
            throw SMB2Client.makeError("Invalid RPC fragment length (\(fragLength)).")
        }

        while buffer.count < fragLength {
            let chunk = try await readPipeChunk(fileId: pipeFileId)
            if chunk.isEmpty {
                throw SMB2Client.makeError("Truncated RPC fragment from SMB server.")
            }
            buffer.append(chunk)
        }

        let pduStart = buffer.startIndex
        let pdu = Data(buffer[pduStart..<(pduStart + fragLength)])
        buffer = Data(buffer[(pduStart + fragLength)...])
        return pdu
    }

    private func readDCERPCResponseStub(pipeFileId: Data, buffer: inout Data) async throws -> Data {
        var stub = Data()
        while true {
            let pdu = try await readDCERPCPDU(pipeFileId: pipeFileId, buffer: &buffer)
            let ptype = pdu[2]
            let pfcFlags = pdu[3]
            if ptype == 3 { // FAULT
                throw SMB2Client.makeError("SMB server returned an RPC fault while enumerating shares.")
            }
            guard ptype == 2, pdu.count >= 24 else {
                throw SMB2Client.makeError("Unexpected RPC response packet type (\(ptype)).")
            }
            let authLen = Int(UInt16(pdu[10]) | (UInt16(pdu[11]) << 8))
            let stubEnd = max(24, pdu.count - authLen)
            if stubEnd > 24 {
                stub.append(pdu.subdata(in: 24..<stubEnd))
            }
            if (pfcFlags & 0x02) != 0 { // PFC_LAST_FRAG
                break
            }
        }
        return stub
    }

    private func buildSRVSVCBindPacket(callId: UInt32) -> Data {
        var packet = Data(capacity: 72)
        // DCE/RPC Common Header (16 bytes)
        packet.append(contentsOf: [5, 0, 11, 0x03]) // ver 5.0, BIND (11), FIRST|LAST
        packet.append(contentsOf: [0x10, 0x00, 0x00, 0x00]) // Little-endian NDR drep
        appendLE(UInt16(72), to: &packet) // frag_length
        appendLE(UInt16(0), to: &packet) // auth_length
        appendLE(callId, to: &packet)

        // Bind header
        appendLE(UInt16(4280), to: &packet) // max_xmit_frag
        appendLE(UInt16(4280), to: &packet) // max_recv_frag
        appendLE(UInt32(0), to: &packet) // assoc_group_id
        packet.append(1) // n_context_elem
        packet.append(contentsOf: [0, 0, 0])

        // Presentation context 0
        appendLE(UInt16(0), to: &packet) // p_cont_id
        packet.append(1) // n_transfer_syn
        packet.append(0) // reserved
        // SRVSVC UUID: 4b324fc8-1670-01d3-1278-5a47bf6ee188 v3.0
        packet.append(contentsOf: [
            0xc8, 0x4f, 0x32, 0x4b,
            0x70, 0x16,
            0xd3, 0x01,
            0x12, 0x78,
            0x5a, 0x47, 0xbf, 0x6e, 0xe1, 0x88
        ])
        appendLE(UInt32(3), to: &packet)
        // NDR Transfer Syntax UUID: 8a885d04-1ceb-11c9-9fe8-08002b104860 v2.0
        packet.append(contentsOf: [
            0x04, 0x5d, 0x88, 0x8a,
            0xeb, 0x1c,
            0xc9, 0x11,
            0x9f, 0xe8,
            0x08, 0x00, 0x2b, 0x10, 0x48, 0x60
        ])
        appendLE(UInt32(2), to: &packet)
        return packet
    }

    private func buildNetrShareEnumRequest(callId: UInt32, resumeHandle: UInt32) -> Data {
        var stub = Data(capacity: 36)
        appendLE(UInt32(0), to: &stub) // ServerName unique ptr = NULL
        appendLE(UInt32(1), to: &stub) // InfoStruct.Level = 1
        appendLE(UInt32(1), to: &stub) // InfoStruct.ShareInfo union switch = 1
        appendLE(UInt32(0x00020000), to: &stub) // ShareInfo1 referent ID
        appendLE(UInt32(0), to: &stub) // EntriesRead = 0
        appendLE(UInt32(0), to: &stub) // Buffer ptr = NULL
        appendLE(UInt32(0xFFFFFFFF), to: &stub) // PreferedMaximumLength = MAX_PREFERRED_LENGTH
        appendLE(UInt32(0x00020004), to: &stub) // ResumeHandle referent ID
        appendLE(resumeHandle, to: &stub) // ResumeHandle value

        let fragLen = UInt16(24 + stub.count)
        var pdu = Data(capacity: Int(fragLen))
        pdu.append(contentsOf: [5, 0, 0, 0x03]) // ver 5.0, REQUEST (0), FIRST|LAST
        pdu.append(contentsOf: [0x10, 0x00, 0x00, 0x00]) // Little-endian NDR drep
        appendLE(fragLen, to: &pdu)
        appendLE(UInt16(0), to: &pdu) // auth_length
        appendLE(callId, to: &pdu)
        appendLE(UInt32(stub.count), to: &pdu) // alloc_hint
        appendLE(UInt16(0), to: &pdu) // p_cont_id
        appendLE(UInt16(15), to: &pdu) // opnum 15 = NetrShareEnum
        pdu.append(stub)
        return pdu
    }

    private func parseNetrShareEnumResponse(stub: Data) throws -> (shares: [String], nextResumeHandle: UInt32?, status: UInt32) {
        var cursor = 0

        func readUInt32() throws -> UInt32 {
            guard cursor + 4 <= stub.count else {
                throw SMB2Client.makeError("Truncated RPC response while reading share list.")
            }
            let val = UInt32(stub[cursor])
                | (UInt32(stub[cursor + 1]) << 8)
                | (UInt32(stub[cursor + 2]) << 16)
                | (UInt32(stub[cursor + 3]) << 24)
            cursor += 4
            return val
        }

        func readNDRUnicodeString() throws -> String {
            _ = try readUInt32() // max_count
            _ = try readUInt32() // offset
            let actualCount = Int(try readUInt32())
            let byteCount = actualCount * 2
            guard actualCount >= 0, cursor + byteCount <= stub.count else {
                throw SMB2Client.makeError("Truncated share name string in RPC response.")
            }
            let raw = stub.subdata(in: cursor..<(cursor + byteCount))
            cursor += byteCount
            let remainder = cursor % 4
            if remainder != 0 {
                cursor = min(stub.count, cursor + (4 - remainder))
            }
            let decoded = String(data: raw, encoding: .utf16LittleEndian) ?? ""
            return decoded.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }

        _ = try readUInt32() // Level
        _ = try readUInt32() // Union discriminant
        let containerPtr = try readUInt32()

        var shares: [String] = []
        if containerPtr != 0 {
            let entriesRead = Int(try readUInt32())
            let bufferPtr = try readUInt32()
            if bufferPtr != 0 && entriesRead > 0 {
                guard entriesRead * 12 <= stub.count - cursor else {
                    throw SMB2Client.makeError("Invalid share entry count (\(entriesRead)) in RPC response.")
                }
                _ = try readUInt32() // conformant max_count
                var descriptors: [(netnamePtr: UInt32, type: UInt32, remarkPtr: UInt32)] = []
                descriptors.reserveCapacity(entriesRead)
                for _ in 0..<entriesRead {
                    let netnamePtr = try readUInt32()
                    let shareType = try readUInt32()
                    let remarkPtr = try readUInt32()
                    descriptors.append((netnamePtr, shareType, remarkPtr))
                }
                for desc in descriptors {
                    let name = desc.netnamePtr != 0 ? try readNDRUnicodeString() : ""
                    if desc.remarkPtr != 0 {
                        _ = try readNDRUnicodeString()
                    }
                    let baseType = desc.type & 0x0FFFFFFF
                    let isSpecial = (desc.type & 0x80000000) != 0
                    if baseType == 0 && !isSpecial && !name.isEmpty && !name.hasSuffix("$") {
                        shares.append(name)
                    }
                }
            }
        }

        _ = try readUInt32() // TotalEntries
        let resumePtr = try readUInt32()
        var nextResumeHandle: UInt32? = nil
        if resumePtr != 0 {
            nextResumeHandle = try readUInt32()
        }
        let status = try readUInt32()
        return (shares, nextResumeHandle, status)
    }

    private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    func createFile(relativePath: String) async throws -> Data {
        let msgId = nextMessageId()
        let req = buildCreatePacket(
            filePath: relativePath,
            isDirectory: false,
            sessionId: sessionId,
            treeId: treeId,
            messageId: msgId
        )
        try await sendFramedPacket(payload: req)
        let resp = try await readCommandResponse(expectedCommand: 5, messageId: msgId)
        guard let parsed = parseSMB2Header(data: resp) else {
            throw SMB2Client.makeError("Failed to parse CREATE response for \(relativePath)")
        }
        guard parsed.status == 0 else {
            throw SMB2Client.makeError("Server failed to create '\(relativePath)': \(SMB2Client.describeStatus(parsed.status))")
        }
        guard resp.count >= 144 else {
            throw SMB2Client.makeError("Truncated CREATE response for \(relativePath)")
        }
        return resp.subdata(in: 128..<144)
    }

    func writeChunk(fileId: Data, offset: UInt64, chunk: Data) async throws {
        let msgId = nextMessageId()
        let req = buildWritePacket(
            fileId: fileId,
            offset: offset,
            chunk: chunk,
            sessionId: sessionId,
            treeId: treeId,
            messageId: msgId
        )
        try await sendFramedPacket(payload: req)
        let resp = try await readCommandResponse(expectedCommand: 9, messageId: msgId)
        guard let parsed = parseSMB2Header(data: resp) else {
            throw SMB2Client.makeError("Failed to parse WRITE response")
        }
        guard parsed.status == 0 else {
            throw SMB2Client.makeError("Server failed to write chunk: \(SMB2Client.describeStatus(parsed.status))")
        }
    }

    func openFileForRead(relativePath: String) async throws -> Data {
        try await openFileForReadWithSize(relativePath: relativePath).fileId
    }

    func openFileForReadWithSize(relativePath: String) async throws -> (fileId: Data, fileSize: UInt64) {
        let msgId = nextMessageId()
        let req = buildCreatePacket(
            filePath: relativePath,
            isDirectory: false,
            disposition: 1, // FILE_OPEN
            desiredAccess: 0x00120089, // FILE_READ_DATA | FILE_READ_EA | FILE_READ_ATTRIBUTES | SYNCHRONIZE
            sessionId: sessionId,
            treeId: treeId,
            messageId: msgId
        )
        try await sendFramedPacket(payload: req)
        let resp = try await readCommandResponse(expectedCommand: 5, messageId: msgId)
        guard let parsed = parseSMB2Header(data: resp) else {
            throw SMB2Client.makeError("Failed to parse CREATE response for reading '\(relativePath)'")
        }
        guard parsed.status == 0 else {
            throw SMB2Client.makeError("Server failed to open '\(relativePath)' for reading: \(SMB2Client.describeStatus(parsed.status))")
        }
        guard resp.count >= 144 else {
            throw SMB2Client.makeError("Truncated CREATE response for reading '\(relativePath)'")
        }
        // SMB2 CREATE response: EndOfFile is 8-byte LE UInt64 at offset 112 (64 header + 48)
        let fileSize = (0..<8).reduce(UInt64(0)) { acc, idx in
            acc | (UInt64(resp[112 + idx]) << UInt64(idx * 8))
        }
        let fileId = resp.subdata(in: 128..<144)
        return (fileId, fileSize)
    }

    func readChunk(fileId: Data, offset: UInt64, length: UInt32) async throws -> Data {
        let msgId = nextMessageId()
        let req = buildReadPacket(
            fileId: fileId,
            offset: offset,
            length: length,
            sessionId: sessionId,
            treeId: treeId,
            messageId: msgId
        )
        try await sendFramedPacket(payload: req)
        let resp = try await readCommandResponse(expectedCommand: 8, messageId: msgId)
        guard let parsed = parseSMB2Header(data: resp), parsed.status == 0 else {
            return Data()
        }
        guard resp.count >= 72 else { return Data() }
        let dataOffset = Int(resp[66])
        let dataLength = Int(UInt32(resp[68]) | (UInt32(resp[69]) << 8) | (UInt32(resp[70]) << 16) | (UInt32(resp[71]) << 24))
        guard dataOffset >= 64, dataOffset + dataLength <= resp.count else { return Data() }
        return resp.subdata(in: dataOffset..<(dataOffset + dataLength))
    }

    func readFileData(relativePath: String, maxBytes: Int = 8 * 1024 * 1024) async throws -> Data {
        let fileId = try await openFileForRead(relativePath: relativePath)
        do {
            var result = Data()
            var currentOffset: UInt64 = 0
            let chunkSize: UInt32 = 64 * 1024
            while result.count < maxBytes {
                if Task.isCancelled { break }
                let toRead = UInt32(min(Int(chunkSize), maxBytes - result.count))
                let chunk = try await readChunk(fileId: fileId, offset: currentOffset, length: toRead)
                if chunk.isEmpty {
                    break
                }
                result.append(chunk)
                currentOffset += UInt64(chunk.count)
                if chunk.count < Int(toRead) {
                    break
                }
            }
            try? await closeFile(fileId: fileId)
            return result
        } catch {
            try? await closeFile(fileId: fileId)
            throw error
        }
    }

    func closeFile(fileId: Data) async throws {
        let msgId = nextMessageId()
        let req = buildClosePacket(
            fileId: fileId,
            sessionId: sessionId,
            treeId: treeId,
            messageId: msgId
        )
        try await sendFramedPacket(payload: req)
        let resp = try await readCommandResponse(expectedCommand: 6, messageId: msgId)
        guard let parsed = parseSMB2Header(data: resp), parsed.status == 0 else {
            return
        }
    }

    func fileExists(relativePath: String) async throws -> Bool {
        let msgId = nextMessageId()
        let req = buildCreatePacket(
            filePath: relativePath,
            isDirectory: false,
            disposition: 1, // FILE_OPEN
            desiredAccess: 0x00100080, // FILE_READ_ATTRIBUTES | SYNCHRONIZE
            sessionId: sessionId,
            treeId: treeId,
            messageId: msgId
        )
        try await sendFramedPacket(payload: req)
        let resp = try await readCommandResponse(expectedCommand: 5, messageId: msgId)
        guard let parsed = parseSMB2Header(data: resp) else {
            return false
        }
        if parsed.status == 0x00000000 {
            if resp.count >= 144 {
                let fileId = resp.subdata(in: 128..<144)
                try? await closeFile(fileId: fileId)
            }
            return true
        }
        return false
    }

    func setFileTimestamps(relativePath: String, date: Date) async throws {
        let openMsgId = nextMessageId()
        let openReq = buildCreatePacket(
            filePath: relativePath,
            isDirectory: false,
            disposition: 1, // FILE_OPEN
            desiredAccess: 0x00100100, // FILE_WRITE_ATTRIBUTES | SYNCHRONIZE
            sessionId: sessionId,
            treeId: treeId,
            messageId: openMsgId
        )
        try await sendFramedPacket(payload: openReq)
        let openResp = try await readCommandResponse(expectedCommand: 5, messageId: openMsgId)
        let openParsed = parseSMB2Header(data: openResp)
        guard let openParsed = openParsed, openParsed.status == 0, openResp.count >= 144 else {
            let statusDesc = openParsed != nil ? SMB2Client.describeStatus(openParsed!.status) : "Invalid SMB Header"
            print("Failed to open '\(relativePath)' for setting timestamps: \(openResp.count < 144 ? "Truncated response" : statusDesc)")
            return
        }
        let fileId = openResp.subdata(in: 128..<144)

        let setMsgId = nextMessageId()
        let setReq = buildSetBasicInfoPacket(
            fileId: fileId,
            date: date,
            sessionId: sessionId,
            treeId: treeId,
            messageId: setMsgId
        )
        try await sendFramedPacket(payload: setReq)
        let setResp = try await readCommandResponse(expectedCommand: 17, messageId: setMsgId)
        if let setParsed = parseSMB2Header(data: setResp) {
            if setParsed.status != 0 {
                print("Warning: SMB2 SET_INFO failed with status: \(SMB2Client.describeStatus(setParsed.status))")
            } else {
                print("Successfully synced photo timestamp (\(date)) to SMB file: \(relativePath)")
            }
        }

        try? await closeFile(fileId: fileId)
    }

    /// Delete a remote file by opening with DELETE access and FILE_DELETE_ON_CLOSE option
    func deleteFile(relativePath: String) async throws {
        try await deleteEntry(relativePath: relativePath, isDirectory: false)
    }

    /// Recursively deletes a remote directory and all of its contents.
    func deleteDirectory(relativePath: String) async throws {
        let clean = relativePath.replacingOccurrences(of: "/", with: "\\").trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
        guard !clean.isEmpty else {
            throw SMB2Client.makeError("Cannot delete share root.")
        }
        let entries = try await queryDirectoryEntries(path: clean, throwOnOpenError: false)
        for entry in entries {
            let childPath = "\(clean)\\\(entry.name)"
            if entry.isDirectory {
                try await deleteDirectory(relativePath: childPath)
            } else {
                try await deleteFile(relativePath: childPath)
            }
        }
        try await deleteEntry(relativePath: clean, isDirectory: true)
    }

    private func deleteEntry(relativePath: String, isDirectory: Bool) async throws {
        let msgId = nextMessageId()
        // FILE_DIRECTORY_FILE (0x01) vs FILE_NON_DIRECTORY_FILE (0x40) + SYNCHRONOUS_IO_NONALERT (0x20) + FILE_DELETE_ON_CLOSE (0x1000)
        let createOptions: UInt32 = isDirectory ? 0x00001021 : 0x00001060
        let req = buildCreatePacket(
            filePath: relativePath,
            isDirectory: isDirectory,
            disposition: 1, // FILE_OPEN
            desiredAccess: 0x00010000, // DELETE
            createOptions: createOptions,
            sessionId: sessionId,
            treeId: treeId,
            messageId: msgId
        )
        try await sendFramedPacket(payload: req)
        let resp = try await readCommandResponse(expectedCommand: 5, messageId: msgId)
        guard let parsed = parseSMB2Header(data: resp) else {
            throw SMB2Client.makeError("Failed to delete '\(relativePath)': Invalid SMB Header")
        }
        // Ignore NOT_FOUND / PATH_NOT_FOUND so deleting an already-absent entry succeeds cleanly
        if parsed.status == 0xC0000034 || parsed.status == 0xC000003A {
            return
        }
        guard parsed.status == 0, resp.count >= 144 else {
            throw SMB2Client.makeError("Failed to delete '\(relativePath)': \(SMB2Client.describeStatus(parsed.status))")
        }
        let fileId = resp.subdata(in: 128..<144)
        try? await closeFile(fileId: fileId)
    }

    func uploadFile(
        localURL: URL,
        remoteRelativePath: String,
        creationDate: Date? = nil,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        let totalBytes = (fileAttributes?[.size] as? UInt64) ?? 0
        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? fileHandle.close() }

        let fileId = try await createFile(relativePath: remoteRelativePath)
        do {
            var offset: UInt64 = 0
            let chunkSize = 65536 // 64 KB
            while true {
                guard !Task.isCancelled else {
                    throw SMB2Client.makeError("Upload cancelled.")
                }
                let chunk = try fileHandle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                try await writeChunk(fileId: fileId, offset: offset, chunk: chunk)
                offset += UInt64(chunk.count)
                if totalBytes > 0 {
                    progressHandler?(min(1.0, Double(offset) / Double(totalBytes)))
                }
            }
            try await closeFile(fileId: fileId)
        } catch {
            try? await closeFile(fileId: fileId)
            // On failure, attempt to remove any partial file from the SMB server if not cancelled
            if !Task.isCancelled {
                try? await deleteFile(relativePath: remoteRelativePath)
            }
            throw error
        }

        // Sync photo timestamp to the SMB filesystem by opening the file specifically for setting attributes
        if let date = creationDate {
            try? await setFileTimestamps(relativePath: remoteRelativePath, date: date)
        }
    }

    func cancel() {
        connection.cancel()
    }

    func disconnect() async {
        connection.cancel()
    }

    // Packet Transport
    private func sendFramedPacket(payload: Data) async throws {
        var framed = Data(capacity: 4 + payload.count)
        let len = payload.count
        framed.append(0x00)
        framed.append(UInt8((len >> 16) & 0xff))
        framed.append(UInt8((len >> 8) & 0xff))
        framed.append(UInt8(len & 0xff))
        framed.append(payload)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func readExact(count: Int) async throws -> Data {
        var accumulated = Data()
        while accumulated.count < count {
            let needed = count - accumulated.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: needed) { content, _, isComplete, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let content = content, !content.isEmpty {
                        continuation.resume(returning: content)
                    } else if isComplete {
                        continuation.resume(throwing: SMB2AuthenticationTester.makeError("Connection closed unexpectedly by server."))
                    }
                }
            }
            accumulated.append(chunk)
        }
        return accumulated
    }

    private func readFramedPacket() async throws -> Data {
        var keepAlives = 0
        while true {
            let lengthHeader = try await readExact(count: 4)
            let msgType = lengthHeader[0]
            let length = (Int(lengthHeader[1]) << 16) | (Int(lengthHeader[2]) << 8) | Int(lengthHeader[3])

            // Discard NetBIOS Session Keep-Alive packets (RFC 1002 Section 4.3.5: type 0x85) or empty heartbeats
            if msgType == 0x85 || (msgType == 0 && length == 0) {
                keepAlives += 1
                if keepAlives > 20 {
                    throw SMB2AuthenticationTester.makeError("Too many keep-alive frames received from SMB server.")
                }
                continue
            }

            guard length > 0 && length <= 1_048_576 else {
                throw SMB2AuthenticationTester.makeError("Invalid SMB frame length: \(length)")
            }
            return try await readExact(count: length)
        }
    }

    // Packet Builders
    private func buildSMB2Header(command: UInt16, messageId: UInt64, sessionId: UInt64, treeId: UInt32 = 0) -> Data {
        var header = Data(count: 64)
        header[0] = 0xfe; header[1] = 0x53; header[2] = 0x4d; header[3] = 0x42
        var structSize = UInt16(64).littleEndian
        header.replaceSubrange(4..<6, with: Data(bytes: &structSize, count: 2))
        var creditCharge: UInt16 = 0
        header.replaceSubrange(6..<8, with: Data(bytes: &creditCharge, count: 2))
        var cmd = command.littleEndian
        header.replaceSubrange(12..<14, with: Data(bytes: &cmd, count: 2))
        var credits = UInt16(32).littleEndian
        header.replaceSubrange(14..<16, with: Data(bytes: &credits, count: 2))
        var msgId = messageId.littleEndian
        header.replaceSubrange(24..<32, with: Data(bytes: &msgId, count: 8))
        var procId = UInt32(0xfeff).littleEndian
        header.replaceSubrange(32..<36, with: Data(bytes: &procId, count: 4))
        var tId = treeId.littleEndian
        header.replaceSubrange(36..<40, with: Data(bytes: &tId, count: 4))
        var sId = sessionId.littleEndian
        header.replaceSubrange(40..<48, with: Data(bytes: &sId, count: 8))
        return header
    }

    private func parseSMB2Header(data: Data) -> (command: UInt16, status: UInt32, messageId: UInt64, sessionId: UInt64, treeId: UInt32)? {
        guard data.count >= 64,
              data[0] == 0xfe && data[1] == 0x53 && data[2] == 0x4d && data[3] == 0x42 else {
            return nil
        }
        let status = UInt32(data[8]) | (UInt32(data[9]) << 8) | (UInt32(data[10]) << 16) | (UInt32(data[11]) << 24)
        let command = UInt16(data[12]) | (UInt16(data[13]) << 8)
        let treeId = UInt32(data[36]) | (UInt32(data[37]) << 8) | (UInt32(data[38]) << 16) | (UInt32(data[39]) << 24)
        var sId: UInt64 = 0
        for i in 0..<8 {
            sId |= UInt64(data[40 + i]) << (i * 8)
        }
        var mId: UInt64 = 0
        for i in 0..<8 {
            mId |= UInt64(data[24 + i]) << (i * 8)
        }
        return (command, status, mId, sId, treeId)
    }

    private func buildCreatePacket(
        filePath: String,
        isDirectory: Bool,
        disposition: UInt32 = 5,
        desiredAccess: UInt32? = nil,
        createOptions: UInt32? = nil,
        sessionId: UInt64,
        treeId: UInt32,
        messageId: UInt64
    ) -> Data {
        let header = buildSMB2Header(command: 5, messageId: messageId, sessionId: sessionId, treeId: treeId)
        let cleanPath = filePath.replacingOccurrences(of: "/", with: "\\")
        let pathData = toUTF16LE(cleanPath)

        var body = Data()
        var structSize = UInt16(57).littleEndian
        body.append(Data(bytes: &structSize, count: 2))
        body.append(0x00) // SecurityFlags
        body.append(0x00) // RequestedOplockLevel
        var impersonation = UInt32(0x02).littleEndian
        body.append(Data(bytes: &impersonation, count: 4))
        var createFlags: UInt64 = 0
        body.append(Data(bytes: &createFlags, count: 8))
        var reserved: UInt64 = 0
        body.append(Data(bytes: &reserved, count: 8))

        if isDirectory {
            var access = (desiredAccess ?? UInt32(0x00100021)).littleEndian // FILE_LIST_DIRECTORY | SYNCHRONIZE
            body.append(Data(bytes: &access, count: 4))
            var fileAttr = UInt32(0x00000010).littleEndian // FILE_ATTRIBUTE_DIRECTORY
            body.append(Data(bytes: &fileAttr, count: 4))
            var shareAccess = UInt32(0x00000007).littleEndian
            body.append(Data(bytes: &shareAccess, count: 4))
            var disp = (disposition == 5 ? UInt32(3) : disposition).littleEndian
            body.append(Data(bytes: &disp, count: 4))
            var options = (createOptions ?? UInt32(0x00000021)).littleEndian // FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT
            body.append(Data(bytes: &options, count: 4))
        } else {
            var access = (desiredAccess ?? UInt32(0x0012019F)).littleEndian // FILE_GENERIC_WRITE | FILE_GENERIC_READ | DELETE
            body.append(Data(bytes: &access, count: 4))
            var fileAttr = UInt32(0x00000080).littleEndian // FILE_ATTRIBUTE_NORMAL
            body.append(Data(bytes: &fileAttr, count: 4))
            var shareAccess = UInt32(0x00000007).littleEndian
            body.append(Data(bytes: &shareAccess, count: 4))
            var disp = disposition.littleEndian
            body.append(Data(bytes: &disp, count: 4))
            var options = (createOptions ?? UInt32(0x00000060)).littleEndian // FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT
            body.append(Data(bytes: &options, count: 4))
        }

        var nameOffset = UInt16(120).littleEndian
        body.append(Data(bytes: &nameOffset, count: 2))
        var nameLen = UInt16(pathData.count).littleEndian
        body.append(Data(bytes: &nameLen, count: 2))
        var ctxOffset: UInt32 = 0
        body.append(Data(bytes: &ctxOffset, count: 4))
        var ctxLen: UInt32 = 0
        body.append(Data(bytes: &ctxLen, count: 4))

        var packet = header
        packet.append(body)
        // SMB2 CREATE StructureSize is 57 (56 fixed bytes + at least 1 Buffer byte even when NameLength is 0)
        if pathData.isEmpty {
            packet.append(0x00)
        } else {
            packet.append(pathData)
        }
        return packet
    }

    private func buildQueryDirectoryPacket(
        dirFileId: Data,
        pattern: String = "*",
        restartScan: Bool,
        sessionId: UInt64,
        treeId: UInt32,
        messageId: UInt64
    ) -> Data {
        let header = buildSMB2Header(command: 14, messageId: messageId, sessionId: sessionId, treeId: treeId)
        let patternData = toUTF16LE(pattern)

        var body = Data()
        var structSize = UInt16(33).littleEndian
        body.append(Data(bytes: &structSize, count: 2))
        body.append(UInt8(1)) // FileInformationClass: FileDirectoryInformation (0x01)
        body.append(restartScan ? UInt8(0x01) : UInt8(0x00)) // Flags: SMB2_RESTART_SCANS (0x01) or 0
        var fileIndex = UInt32(0)
        body.append(Data(bytes: &fileIndex, count: 4))
        body.append(dirFileId) // 16 bytes
        var fileNameOffset = UInt16(96).littleEndian // 64 (header) + 32 (body before buffer)
        body.append(Data(bytes: &fileNameOffset, count: 2))
        var fileNameLength = UInt16(patternData.count).littleEndian
        body.append(Data(bytes: &fileNameLength, count: 2))
        var outputBufferLength = UInt32(65536).littleEndian
        body.append(Data(bytes: &outputBufferLength, count: 4))

        var packet = header
        packet.append(body)
        packet.append(patternData)
        return packet
    }

    private func buildSetBasicInfoPacket(
        fileId: Data,
        date: Date,
        sessionId: UInt64,
        treeId: UInt32,
        messageId: UInt64
    ) -> Data {
        let header = buildSMB2Header(command: 17, messageId: messageId, sessionId: sessionId, treeId: treeId)

        let secondsBetween1601And1970: Double = 11644473600.0
        let filetime = UInt64((date.timeIntervalSince1970 + secondsBetween1601And1970) * 10_000_000.0)

        var body = Data()
        var structSize = UInt16(33).littleEndian // StructureSize must be 33
        body.append(Data(bytes: &structSize, count: 2))
        body.append(UInt8(0x01)) // InfoType: SMB2_0_INFO_FILE
        body.append(UInt8(0x04)) // FileInfoClass: FileBasicInformation
        var bufferLength = UInt32(40).littleEndian // Length of FileBasicInformation
        body.append(Data(bytes: &bufferLength, count: 4))
        var bufferOffset = UInt16(96).littleEndian // 64 (header) + 32 (body before buffer)
        body.append(Data(bytes: &bufferOffset, count: 2))
        var reserved = UInt16(0)
        body.append(Data(bytes: &reserved, count: 2))
        var additionalInfo = UInt32(0)
        body.append(Data(bytes: &additionalInfo, count: 4))
        body.append(fileId) // 16 bytes

        // FileBasicInformation (40 bytes)
        var buffer = Data()
        var ftCreation = filetime.littleEndian
        buffer.append(Data(bytes: &ftCreation, count: 8)) // CreationTime
        var ftAccess = filetime.littleEndian
        buffer.append(Data(bytes: &ftAccess, count: 8)) // LastAccessTime
        var ftWrite = filetime.littleEndian
        buffer.append(Data(bytes: &ftWrite, count: 8)) // LastWriteTime (Modified)
        var ftChange = filetime.littleEndian
        buffer.append(Data(bytes: &ftChange, count: 8)) // ChangeTime
        var fileAttributes = UInt32(0).littleEndian
        buffer.append(Data(bytes: &fileAttributes, count: 4)) // FileAttributes (0 = no change)
        var bufferReserved = UInt32(0).littleEndian
        buffer.append(Data(bytes: &bufferReserved, count: 4)) // Reserved

        var packet = header
        packet.append(body)
        packet.append(buffer)
        return packet
    }

    private func buildSetRenameInfoPacket(
        fileId: Data,
        newRelativePath: String,
        replaceIfExists: Bool,
        sessionId: UInt64,
        treeId: UInt32,
        messageId: UInt64
    ) -> Data {
        let header = buildSMB2Header(command: 17, messageId: messageId, sessionId: sessionId, treeId: treeId)
        let nameData = toUTF16LE(newRelativePath)

        // FILE_RENAME_INFORMATION_TYPE_2: ReplaceIfExists(1) + Reserved(7) + RootDirectory(8) + FileNameLength(4) + FileName
        var buffer = Data()
        buffer.append(UInt8(replaceIfExists ? 1 : 0))
        buffer.append(Data(repeating: 0, count: 7))
        buffer.append(Data(repeating: 0, count: 8))
        var fileNameLen = UInt32(nameData.count).littleEndian
        buffer.append(Data(bytes: &fileNameLen, count: 4))
        buffer.append(nameData)

        var body = Data()
        var structSize = UInt16(33).littleEndian
        body.append(Data(bytes: &structSize, count: 2))
        body.append(UInt8(0x01)) // InfoType: SMB2_0_INFO_FILE
        body.append(UInt8(0x0A)) // FileInfoClass: FileRenameInformation
        var bufferLength = UInt32(buffer.count).littleEndian
        body.append(Data(bytes: &bufferLength, count: 4))
        var bufferOffset = UInt16(96).littleEndian
        body.append(Data(bytes: &bufferOffset, count: 2))
        var reserved = UInt16(0)
        body.append(Data(bytes: &reserved, count: 2))
        var additionalInfo = UInt32(0)
        body.append(Data(bytes: &additionalInfo, count: 4))
        body.append(fileId)

        var packet = header
        packet.append(body)
        packet.append(buffer)
        return packet
    }

    private func buildWritePacket(
        fileId: Data,
        offset: UInt64,
        chunk: Data,
        sessionId: UInt64,
        treeId: UInt32,
        messageId: UInt64
    ) -> Data {
        let header = buildSMB2Header(command: 9, messageId: messageId, sessionId: sessionId, treeId: treeId)
        var body = Data()
        var structSize = UInt16(49).littleEndian
        body.append(Data(bytes: &structSize, count: 2))
        var dataOffset = UInt16(112).littleEndian
        body.append(Data(bytes: &dataOffset, count: 2))
        var len = UInt32(chunk.count).littleEndian
        body.append(Data(bytes: &len, count: 4))
        var off = offset.littleEndian
        body.append(Data(bytes: &off, count: 8))
        body.append(fileId) // 16 bytes
        var channel: UInt32 = 0
        body.append(Data(bytes: &channel, count: 4))
        var remaining: UInt32 = 0
        body.append(Data(bytes: &remaining, count: 4))
        var chOffset: UInt16 = 0
        body.append(Data(bytes: &chOffset, count: 2))
        var chLen: UInt16 = 0
        body.append(Data(bytes: &chLen, count: 2))
        var flags: UInt32 = 0
        body.append(Data(bytes: &flags, count: 4))

        var packet = header
        packet.append(body)
        packet.append(chunk)
        return packet
    }

    private func buildReadPacket(
        fileId: Data,
        offset: UInt64,
        length: UInt32,
        sessionId: UInt64,
        treeId: UInt32,
        messageId: UInt64
    ) -> Data {
        let header = buildSMB2Header(command: 8, messageId: messageId, sessionId: sessionId, treeId: treeId)
        var body = Data()
        var structSize = UInt16(49).littleEndian
        body.append(Data(bytes: &structSize, count: 2))
        body.append(0x00) // Padding
        body.append(0x00) // Flags
        var len = length.littleEndian
        body.append(Data(bytes: &len, count: 4))
        var off = offset.littleEndian
        body.append(Data(bytes: &off, count: 8))
        body.append(fileId) // 16 bytes
        var minCount: UInt32 = 0
        body.append(Data(bytes: &minCount, count: 4))
        var channel: UInt32 = 0
        body.append(Data(bytes: &channel, count: 4))
        var remaining: UInt32 = 0
        body.append(Data(bytes: &remaining, count: 4))
        var chOffset: UInt16 = 0
        body.append(Data(bytes: &chOffset, count: 2))
        var chLen: UInt16 = 0
        body.append(Data(bytes: &chLen, count: 2))
        body.append(0x00) // Buffer (1 byte)

        var packet = header
        packet.append(body)
        return packet
    }

    private func buildClosePacket(fileId: Data, sessionId: UInt64, treeId: UInt32, messageId: UInt64) -> Data {
        let header = buildSMB2Header(command: 6, messageId: messageId, sessionId: sessionId, treeId: treeId)
        var body = Data()
        var structSize = UInt16(24).littleEndian
        body.append(Data(bytes: &structSize, count: 2))
        var flags: UInt16 = 0
        body.append(Data(bytes: &flags, count: 2))
        var reserved: UInt32 = 0
        body.append(Data(bytes: &reserved, count: 4))
        body.append(fileId) // 16 bytes

        var packet = header
        packet.append(body)
        return packet
    }

    private func toUTF16LE(_ str: String) -> Data {
        let chars = Array(str.utf16)
        var data = Data(capacity: chars.count * 2)
        for ch in chars {
            var le = ch.littleEndian
            data.append(Data(bytes: &le, count: 2))
        }
        return data
    }
}

