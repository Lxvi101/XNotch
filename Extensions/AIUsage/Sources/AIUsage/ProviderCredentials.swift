import Foundation
import LocalAuthentication
import Security

// MARK: Keychain

enum KeychainRead: Equatable, Sendable {
    case found(Data)
    case notFound
    /// Reading would show a macOS prompt, which only a click may do.
    case interactionRequired
    case denied
    case failed(OSStatus)
}

/// Reads foreign Keychain items (Claude Code's login). Background reads never show UI.
protocol KeychainReading: Sendable {
    /// Whether a generic password exists, from its attributes alone, which never prompts.
    func exists(service: String) -> Bool
    func read(service: String, interactive: Bool) -> KeychainRead
}

/// XNotch's own Keychain items, for secrets the user pastes in (a cursor.com cookie).
protocol SecretStore: Sendable {
    func read(_ name: String, interactive: Bool) -> KeychainRead
    func write(_ name: String, value: Data) -> OSStatus
    func delete(_ name: String) -> OSStatus
    func exists(_ name: String) -> Bool
}

struct SystemKeychain: KeychainReading, SecretStore {
    static let ownService = "dev.levi.XNotch.ai-usage"

    func exists(service: String) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        Self.disallowUI(&query)
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func read(service: String, interactive: Bool) -> KeychainRead {
        // Several items can share the service; the newest is the live login.
        var listing: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        Self.disallowUI(&listing)
        var rows: CFTypeRef?
        let listStatus = SecItemCopyMatching(listing as CFDictionary, &rows)
        if listStatus == errSecItemNotFound { return .notFound }
        let account = ((rows as? [[String: Any]]) ?? [])
            .max { ($0[kSecAttrModificationDate as String] as? Date ?? .distantPast)
                < ($1[kSecAttrModificationDate as String] as? Date ?? .distantPast) }?[kSecAttrAccount as String] as? String
        // Claude Code writes its login with /usr/bin/security, and each token refresh resets the item's
        // access list to that tool, dropping any Always Allow XNotch was given. Reading through the same
        // tool is always permitted, so it doesn't prompt.
        if let account, let read = Self.readWithSecurityTool(service: service, account: account) { return read }
        return readData(service: service, account: account, interactive: interactive)
    }

    /// nil when the tool couldn't read the item, so the caller falls back to the Keychain API.
    private static func readWithSecurityTool(service: String, account: String) -> KeychainRead? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeout)
        defer { timeout.cancel() }
        var data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0: break
        case 44: return .notFound  // errSecItemNotFound
        default: return nil
        }
        if data.last == UInt8(ascii: "\n") { data.removeLast() }
        // `-w` prints the secret as hex when it holds non-ASCII bytes.
        if data.first != UInt8(ascii: "{"), let decoded = Data(hex: data) { data = decoded }
        return data.isEmpty ? nil : .found(data)
    }

    func read(_ name: String, interactive: Bool) -> KeychainRead {
        readData(service: Self.ownService, account: name, interactive: interactive)
    }

    func write(_ name: String, value: Data) -> OSStatus {
        _ = delete(name)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.ownService,
            kSecAttrAccount as String: name,
            kSecAttrLabel as String: "XNotch AI Usage",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: value,
        ]
        return SecItemAdd(item as CFDictionary, nil)
    }

    func delete(_ name: String) -> OSStatus {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.ownService,
            kSecAttrAccount as String: name,
        ]
        Self.disallowUI(&query)
        return SecItemDelete(query as CFDictionary)
    }

    func exists(_ name: String) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.ownService,
            kSecAttrAccount as String: name,
            kSecReturnAttributes as String: true,
        ]
        Self.disallowUI(&query)
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private func readData(service: String, account: String?, interactive: Bool) -> KeychainRead {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if !interactive { Self.disallowUI(&query) }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .failed(status) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            return .interactionRequired
        case errSecUserCanceled, errSecAuthFailed, errSecNoAccessForItem:
            return interactive ? .denied : .interactionRequired
        default:
            return .failed(status)
        }
    }

    /// `interactionNotAllowed` alone can still surface a legacy Allow/Deny alert, so the deprecated
    /// UI-fail policy is set too. Both the key (`kSecUseAuthenticationUI`, "u_AuthUI") and its value are
    /// spelled out or looked up at runtime to avoid referencing deprecated symbols.
    private static func disallowUI(_ query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query["u_AuthUI"] = uiFailPolicy
    }

    private static let uiFailPolicy: String = {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else {
            return "u_AuthUIF"
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else { return "u_AuthUIF" }
        let value = symbol.assumingMemoryBound(to: CFString?.self).pointee
        return (value as String?) ?? "u_AuthUIF"
    }()
}

private extension Data {
    /// Decodes ASCII hex digits, or nil if `hex` isn't an even run of them.
    init?(hex: Data) {
        guard !hex.isEmpty, hex.count.isMultiple(of: 2) else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let high = nibble(hex[index]), let low = nibble(hex[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }
}

// MARK: Claude Code

struct ClaudeOAuthCredentials: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var scopes: [String]
    var rateLimitTier: String?
    var subscriptionType: String?

    enum ParseError: Error, Equatable {
        /// The Keychain item only holds MCP server logins, not the Claude subscription.
        case mcpOnly
        case malformed
        case missingOAuth
        case missingAccessToken
    }

    static func parse(_ data: Data) throws -> ClaudeOAuthCredentials {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ParseError.malformed
        }
        if root["claudeAiOauth"] == nil, root["mcpOAuth"] != nil { throw ParseError.mcpOnly }
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else { throw ParseError.missingOAuth }
        guard let token = (oauth["accessToken"] as? String).nonEmpty else { throw ParseError.missingAccessToken }
        // Claude Code writes expiresAt in milliseconds since the epoch.
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return ClaudeOAuthCredentials(
            accessToken: token,
            refreshToken: (oauth["refreshToken"] as? String).nonEmpty,
            expiresAt: expiresAt,
            scopes: oauth["scopes"] as? [String] ?? [],
            rateLimitTier: (oauth["rateLimitTier"] as? String).nonEmpty,
            subscriptionType: (oauth["subscriptionType"] as? String).nonEmpty)
    }

    /// Stable across access-token refreshes as long as the refresh token stays the same.
    var fingerprint: String { Hashing.key("claude-credential", refreshToken ?? accessToken) }

    func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }

    /// `claude setup-token` tokens carry only inference scope and can't read usage.
    var canReadUsage: Bool { scopes.isEmpty || scopes.contains("user:profile") }

    var planLabel: String? {
        let words = [subscriptionType, rateLimitTier].compactMap { $0?.lowercased() }.joined(separator: " ")
        let plan: String
        if words.contains("max") { plan = "Max" }
        else if words.contains("pro") { plan = "Pro" }
        else if words.contains("team") { plan = "Team" }
        else if words.contains("enterprise") { plan = "Enterprise" }
        else { return nil }
        // "default_claude_max_20x" → "Max 20x"
        if plan == "Max", let tier = rateLimitTier?.lowercased(),
           let multiplier = tier.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
               .first(where: { $0.hasSuffix("x") && Int($0.dropLast()) != nil }) {
            return "Max \(multiplier)"
        }
        return plan
    }
}

/// Finds Claude Code's subscription login, read-only: the credentials file first, then (with the
/// user's consent) the `Claude Code-credentials` Keychain item.
struct ClaudeCredentialLocator: Sendable {
    static let keychainService = "Claude Code-credentials"

    var environment: [String: String] = ProcessInfo.processInfo.environment
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var keychain: KeychainReading = SystemKeychain()

    var configRoot: URL {
        if let custom = environment["CLAUDE_CONFIG_DIR"].nonEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".claude", isDirectory: true)
    }

    var credentialsFile: URL { configRoot.appendingPathComponent(".credentials.json") }

    /// A custom config dir is its own profile: never borrow the default profile's Keychain login.
    var usesDefaultProfile: Bool { environment["CLAUDE_CONFIG_DIR"].nonEmpty == nil }

    /// Whether Claude Code's login is only in the Keychain and XNotch can't read it yet. Never prompts.
    func needsKeychainAccess(consented: Bool) -> Bool {
        if let data = try? Data(contentsOf: credentialsFile), (try? ClaudeOAuthCredentials.parse(data)) != nil { return false }
        guard usesDefaultProfile, keychain.exists(service: Self.keychainService) else { return false }
        guard consented else { return true }
        if case .found = keychain.read(service: Self.keychainService, interactive: false) { return false }
        return true
    }

    func load(keychainAllowed: Bool, interactive: Bool) throws -> (ClaudeOAuthCredentials, CredentialSource) {
        var fileProblem: ClaudeOAuthCredentials.ParseError?
        if let data = try? Data(contentsOf: credentialsFile) {
            do {
                return (try ClaudeOAuthCredentials.parse(data), .claudeCredentialsFile)
            } catch let error as ClaudeOAuthCredentials.ParseError {
                fileProblem = error
            }
        }

        guard usesDefaultProfile, keychain.exists(service: Self.keychainService) else {
            if fileProblem == .mcpOnly {
                throw ProviderFailure(.notConnected, "Claude Code's saved login only covers MCP servers. "
                    + AIProviderID.claude.signInHint)
            }
            throw ProviderFailure(.notConnected, AIProviderID.claude.signInHint)
        }
        guard keychainAllowed else {
            throw ProviderFailure(.needsKeychainAccess,
                                  "Claude Code keeps its login in your Keychain. Allow access in Settings → AI Usage.")
        }
        switch keychain.read(service: Self.keychainService, interactive: interactive) {
        case let .found(data):
            do {
                return (try ClaudeOAuthCredentials.parse(data), .claudeKeychain)
            } catch ClaudeOAuthCredentials.ParseError.mcpOnly {
                throw ProviderFailure(.notConnected, "Claude Code's Keychain item only holds MCP server logins. "
                    + AIProviderID.claude.signInHint)
            } catch {
                throw ProviderFailure(.notConnected, "Claude Code's Keychain login couldn't be read. "
                    + AIProviderID.claude.signInHint)
            }
        case .notFound:
            throw ProviderFailure(.notConnected, AIProviderID.claude.signInHint)
        case .interactionRequired:
            throw ProviderFailure(.needsKeychainAccess,
                                  "macOS needs your OK before XNotch reads Claude Code's login. Allow access in Settings → AI Usage.")
        case .denied:
            throw ProviderFailure(.needsKeychainAccess,
                                  "Keychain access was denied. Allow access in Settings → AI Usage and choose Always Allow.")
        case let .failed(status):
            throw ProviderFailure(.unavailable, "Couldn't read Claude Code's Keychain login (\(status)).")
        }
    }
}

// MARK: Codex

struct CodexCredentials: Equatable, Sendable {
    var accessToken: String
    var accountID: String?
    var expiresAt: Date?
    var userID: String?
    var email: String?
    var planType: String?

    /// User plus workspace, so two people in one workspace (or one person in two) stay apart.
    var accountKey: String { Hashing.key("codex-account", userID ?? "", accountID ?? "") }
    var fingerprint: String { Hashing.key("codex-credential", accessToken) }

    static func parse(_ data: Data) throws -> CodexCredentials {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderFailure(.notConnected, "Codex's auth.json couldn't be read. Run `codex login` to sign in again.")
        }
        guard let tokens = root["tokens"] as? [String: Any],
              let access = ((tokens["access_token"] ?? tokens["accessToken"]) as? String).nonEmpty else {
            if (root["OPENAI_API_KEY"] as? String).nonEmpty != nil {
                throw ProviderFailure(.notConnected, "Codex is using an OpenAI API key, which has no subscription quota. "
                    + "Run `codex login` and choose ChatGPT to see plan limits.")
            }
            throw ProviderFailure(.notConnected, "Codex's auth.json has no ChatGPT login. Run `codex login`.")
        }
        let idToken = ((tokens["id_token"] ?? tokens["idToken"]) as? String).nonEmpty
        let idClaims = idToken.flatMap(JWT.claims) ?? [:]
        let accessClaims = JWT.claims(access) ?? [:]
        let auth = (idClaims["https://api.openai.com/auth"] ?? accessClaims["https://api.openai.com/auth"]) as? [String: Any]
        let accountID = ((tokens["account_id"] ?? tokens["accountId"]) as? String).nonEmpty
            ?? (idClaims["chatgpt_account_id"] as? String).nonEmpty
            ?? (auth?["chatgpt_account_id"] as? String).nonEmpty
        let profile = (idClaims["https://api.openai.com/profile"] ?? accessClaims["https://api.openai.com/profile"]) as? [String: Any]
        return CodexCredentials(
            accessToken: access,
            accountID: accountID,
            expiresAt: JWT.expiry(access),
            userID: (auth?["chatgpt_user_id"] as? String).nonEmpty ?? (idClaims["sub"] as? String).nonEmpty
                ?? (accessClaims["sub"] as? String).nonEmpty,
            email: (idClaims["email"] as? String).nonEmpty ?? (profile?["email"] as? String).nonEmpty,
            planType: (auth?["chatgpt_plan_type"] as? String).nonEmpty)
    }
}

struct CodexHome: Sendable {
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var home: URL = FileManager.default.homeDirectoryForCurrentUser

    var root: URL {
        if let custom = environment["CODEX_HOME"].nonEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    var authFile: URL { root.appendingPathComponent("auth.json") }
    var configFile: URL { root.appendingPathComponent("config.toml") }

    /// Read-only. Codex owns this file and its token rotation; XNotch never writes it.
    func loadCredentials() throws -> CodexCredentials {
        guard let data = try? Data(contentsOf: authFile) else {
            throw ProviderFailure(.notConnected, AIProviderID.codex.signInHint)
        }
        return try CodexCredentials.parse(data)
    }

    /// `chatgpt_base_url` from config.toml, if set.
    func configuredBaseURL() -> String? {
        guard let contents = try? String(contentsOf: configFile, encoding: .utf8) else { return nil }
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "chatgpt_base_url" else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            return value.nonEmpty
        }
        return nil
    }
}
